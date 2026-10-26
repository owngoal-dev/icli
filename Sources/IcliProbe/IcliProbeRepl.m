#import "IcliProbe.h"

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Source completeness and the interactive REPL. The completeness scan decides
// whether a line ends a statement or opens one the REPL waits to finish; it is
// ported from vphoned's session and needs no context. The REPL runs inline in
// the icli process, so unlike vphoned's session process it never calls setsid
// or claims the controlling terminal — doing so would detach icli's own group.

// MARK: - Source Completeness

static bool icli_probe_is_word(char character) {
    return character == '_' || character == '$' ||
           (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9');
}

/// Whether a '/' here opens a regular expression rather than dividing. After
/// a value — a name, a number, a string, or a closing bracket — it divides;
/// after an operator, an opening bracket, or a keyword that takes an
/// expression, there is nothing for it to divide.
static bool icli_probe_regex_starts(const char *source, const char *last) {
    if (!last) return true;
    char previous = *last;
    if (previous == ')' || previous == ']' || previous == '}' ||
        previous == '\'' || previous == '"' || previous == '`') {
        return false;
    }
    if (!icli_probe_is_word(previous)) return true;
    const char *start = last;
    while (start > source && icli_probe_is_word(start[-1])) start--;
    size_t length = (size_t)(last + 1 - start);
    static const char *const keywords[] = {
        "return", "typeof", "case", "in", "of", "new", "delete",
        "do", "else", "void", "instanceof", "yield", "await", "throw",
    };
    for (size_t index = 0; index < sizeof(keywords) / sizeof(*keywords); index++) {
        if (strlen(keywords[index]) == length && strncmp(start, keywords[index], length) == 0) {
            return true;
        }
    }
    return false;
}

/// The character after a regular expression's closing '/', or NULL when the
/// line ends first. A literal cannot span lines, so an unterminated one is a
/// syntax error for the engine to report rather than a statement to wait for.
static const char *icli_probe_after_regex(const char *slash) {
    bool in_class = false;
    for (const char *cursor = slash + 1; *cursor && *cursor != '\n'; cursor++) {
        if (*cursor == '\\') {
            if (!cursor[1] || cursor[1] == '\n') return NULL;
            cursor++;
            continue;
        }
        if (in_class) {
            if (*cursor == ']') in_class = false;
            continue;
        }
        if (*cursor == '[') in_class = true;
        else if (*cursor == '/') return cursor + 1;
    }
    return NULL;
}

/// Whether `source` ends inside an open brace, bracket, template literal or
/// block comment, which the REPL continues on the next line rather than
/// evaluating. Not static only so the host test can check it directly; it is
/// no part of the target's interface.
bool icli_probe_source_is_incomplete(const char *source) {
    if (!source) return false;
    int depth = 0;
    char quote = '\0';
    bool comment = false;
    // The last character that was not space. A '/' means one thing after a
    // value and another after an operator, and reading a regular expression
    // as a division is what makes `/['"]/` look like an unterminated string
    // and `/\{/` like an unclosed brace — either of which would leave the
    // REPL waiting for a line that is never coming.
    const char *last = NULL;
    for (const char *cursor = source; *cursor; cursor++) {
        char character = *cursor;
        if (comment) {
            if (character == '*' && cursor[1] == '/') {
                comment = false;
                cursor++;
                last = cursor;
            }
            continue;
        }
        if (quote) {
            if (character == '\\' && cursor[1]) {
                cursor++;
            } else if (character == quote) {
                quote = '\0';
                last = cursor;
            }
            continue;
        }
        switch (character) {
        case '\'': case '"': case '`': quote = character; break;
        case '/':
            if (cursor[1] == '*') {
                comment = true;
                cursor++;
                continue;
            }
            if (cursor[1] == '/') {
                while (cursor[1] && cursor[1] != '\n') cursor++;
                continue;
            }
            if (icli_probe_regex_starts(source, last)) {
                const char *after = icli_probe_after_regex(cursor);
                if (after) {
                    cursor = after - 1;
                    last = cursor;
                    continue;
                }
            }
            break;
        case '(': case '[': case '{': depth++; break;
        case ')': case ']': case '}': if (depth > 0) depth--; break;
        default: break;
        }
        if (character != ' ' && character != '\t' && character != '\n' && character != '\r') {
            last = cursor;
        }
    }
    // A single- or double-quoted string cannot span lines in JavaScript, so
    // only a template literal keeps the statement open.
    return depth > 0 || comment || quote == '`';
}

// MARK: - Reading Lines

static volatile sig_atomic_t icli_probe_interrupted = 0;
static volatile sig_atomic_t icli_probe_in_line_editor = 0;
static sigjmp_buf icli_probe_line_editor_exit;

/// libedit's readline swallows ^C and goes on reading, so ^C leaves it by a
/// jump. That abandons libedit mid-line, which is safe only because the REPL
/// reads again straight away: the next readline resets the line, the
/// terminal mode and libedit's signal handlers before anything else runs.
static void icli_probe_note_interrupt(int signal_number) {
    (void)signal_number;
    icli_probe_interrupted = 1;
    if (icli_probe_in_line_editor) siglongjmp(icli_probe_line_editor_exit, 1);
}

static char *(*icli_probe_readline)(const char *);
static void (*icli_probe_add_history)(const char *);

/// libedit gives the REPL history and line editing. It is not a given on every
/// device, and the terminal's own canonical mode still handles backspace, ^U
/// and ^C without it.
static void icli_probe_load_line_editor(void) {
    void *library = dlopen("/usr/lib/libedit.3.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) library = dlopen("libedit.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return;
    icli_probe_readline = dlsym(library, "readline");
    icli_probe_add_history = dlsym(library, "add_history");
    if (!icli_probe_readline) icli_probe_add_history = NULL;
}

/// One line without its newline, malloc-owned, or NULL at end of input.
/// `*interrupted` is set when ^C arrived instead of a line.
static char *icli_probe_read_line(const char *prompt, bool *interrupted) {
    *interrupted = false;
    icli_probe_interrupted = 0;
    if (icli_probe_readline) {
        if (sigsetjmp(icli_probe_line_editor_exit, 1)) {
            icli_probe_in_line_editor = 0;
            *interrupted = true;
            return NULL;
        }
        icli_probe_in_line_editor = 1;
        char *line = icli_probe_readline(prompt);
        icli_probe_in_line_editor = 0;
        if (line && *line && icli_probe_add_history) icli_probe_add_history(line);
        return line;
    }

    fputs(prompt, stdout);
    fflush(stdout);
    char bytes[4096];
    if (!fgets(bytes, sizeof(bytes), stdin)) {
        if (icli_probe_interrupted) {
            *interrupted = true;
            clearerr(stdin);
        }
        return NULL;
    }
    size_t length = strlen(bytes);
    while (length > 0 && (bytes[length - 1] == '\n' || bytes[length - 1] == '\r')) {
        bytes[--length] = '\0';
    }
    return strdup(bytes);
}

// MARK: - The REPL

static const char *icli_probe_help =
    "icli probe. Everything here runs inline, in this process.\n"
    "\n"
    "  ObjC.use('NSProcessInfo')      a class; call its methods by name\n"
    "  ObjC.classes.NSFileManager     the same, by property\n"
    "  obj.setValue_forKey_(v, k)     an underscore stands for a colon\n"
    "  obj['setValue:forKey:'](v, k)  or write the selector out\n"
    "  obj.$value   obj.$class        a collection as plain JSON; its class\n"
    "  api('svc.list', {})            an icli capability, in process\n"
    "  fs.ls / read / write / stat    files, with this process's access\n"
    "  console.log, print, sleep(ms)  output and waiting\n"
    "  .exit  .help                   leave, or print this again\n"
    "  ^C                             abandon a half-finished statement;\n"
    "                                 while one runs, it ends this process\n";

int icli_probe_repl(void) {
    // A failed first evaluation is how a missing JavaScriptCore or a failed
    // prelude surfaces; evaluate a trivial statement to build the context and
    // report either here, before the banner.
    char *failure = NULL;
    char *started = icli_probe_evaluate("1", &failure, NULL);
    if (!started) {
        fprintf(stderr, "%s\n", failure ?: "The probe could not start");
        free(failure);
        return 70;
    }
    free(started);

    icli_probe_load_line_editor();
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    printf("icli probe on %ld.%ld.%ld, pid %d. .help for what is here.\n",
           (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion, getpid());
    fflush(stdout);

    // ^C is caught only while a line is read. While a statement runs, SIGINT
    // keeps the host's own disposition: inline, nothing else could stop a
    // runaway statement, so for icli ^C then ends the process.
    struct sigaction note = {.sa_handler = icli_probe_note_interrupt};
    sigemptyset(&note.sa_mask);
    NSMutableString *pending = [NSMutableString string];
    for (;;) {
        struct sigaction previous;
        sigaction(SIGINT, &note, &previous);
        bool interrupted = false;
        char *line = icli_probe_read_line(pending.length ? "   ... " : "probe> ", &interrupted);
        sigaction(SIGINT, &previous, NULL);
        if (interrupted) {
            [pending setString:@""];
            fputs("\n", stdout);
            continue;
        }
        if (!line) break;
        NSString *text = @(line);
        free(line);

        if (!pending.length) {
            NSString *command = [text stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([command isEqualToString:@".exit"] || [command isEqualToString:@".quit"]) break;
            if ([command isEqualToString:@".help"]) {
                fputs(icli_probe_help, stdout);
                fflush(stdout);
                continue;
            }
            if (!command.length) continue;
        }
        [pending appendString:text ?: @""];
        [pending appendString:@"\n"];
        if (icli_probe_source_is_incomplete(pending.UTF8String)) continue;

        char *error = NULL;
        char *described = icli_probe_evaluate(pending.UTF8String, &error, NULL);
        [pending setString:@""];
        if (described) {
            if (strcmp(described, "undefined") != 0) printf("%s\n", described);
            free(described);
        } else {
            fprintf(stderr, "%s\n", error ?: "Unknown error");
            free(error);
        }
        fflush(stdout);
        fflush(stderr);
    }
    return 0;
}
