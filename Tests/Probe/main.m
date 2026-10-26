#import "IcliProbe.h"

#import <Foundation/Foundation.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Checks the probe on the Mac, which has JavaScriptCore: the runtime, the
// ObjC reflection bridge and its ownership rules, the prelude's globals and
// their deliberate absences (no proc.run, no exit), output capture and its
// cap, the api() handler mechanism, and the REPL's source-completeness scan.
// It links no framework but Foundation, so a green run also proves the
// dlopen-only loading works. `scripts/test-probe.sh` builds it.

// The REPL's completeness scan, which IcliProbeRepl.m defines and keeps out of
// the target's interface; this harness compiles that file directly.
bool icli_probe_source_is_incomplete(const char *source);

static int checks;
static int failures;

static void expect(bool condition, const char *format, ...) {
    checks++;
    if (condition) return;
    failures++;
    va_list arguments;
    va_start(arguments, format);
    fputs("FAIL: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
}

// MARK: - Evaluation Helpers

/// The described value of `source`, or nil with the error reported. With
/// `output`, what the script printed is collected into it.
static NSString *evaluateCollecting(const char *source, NSString **output) {
    char *failure = NULL;
    char *printed = NULL;
    char *described = icli_probe_evaluate(source, &failure, output ? &printed : NULL);
    if (output) *output = @(printed ?: "");
    free(printed);
    if (!described) {
        NSString *message = @(failure ?: "Unknown error");
        free(failure);
        expect(false, "%s threw %s", source, message.UTF8String);
        return nil;
    }
    NSString *text = @(described);
    free(described);
    return text;
}

static NSString *evaluate(const char *source) {
    return evaluateCollecting(source, NULL);
}

static void expectValue(const char *source, NSString *expected) {
    NSString *actual = evaluate(source);
    if (!actual) return;
    expect([actual isEqualToString:expected], "%s: expected %s, got %s",
           source, expected.UTF8String, actual.UTF8String);
}

/// The error message `source` raised, or nil when it did not raise one.
static NSString *expectThrows(const char *source) {
    char *failure = NULL;
    char *described = icli_probe_evaluate(source, &failure, NULL);
    checks++;
    if (described) {
        failures++;
        fprintf(stderr, "FAIL: %s should have thrown, returned %s\n", source, described);
        free(described);
        return nil;
    }
    NSString *message = @(failure ?: "");
    free(failure);
    return message;
}

static void expectThrowsContaining(const char *source, NSString *fragment) {
    NSString *message = expectThrows(source);
    if (!message) return;
    expect([message containsString:fragment], "%s: expected an error naming %s, got %s",
           source, fragment.UTF8String, message.UTF8String);
}

// MARK: - The Runtime

static void runtimeBasics(void) {
    expect(icli_probe_available(), "JavaScriptCore is available on the Mac");

    expectValue("1 + 2", @"3");
    expectValue("'a' + 'b'", @"ab");
    expectValue("[1, 2, 3].map(function (n) { return n * 2; })", @"[2,4,6]");
    expectValue("JSON.stringify({a: 1})", @"{\"a\":1}");
    expectValue("({a: 1, b: [2]})", @"{\"a\":1,\"b\":[2]}");
    expectValue("null", @"null");
    expectValue("undefined", @"undefined");
    // The one shared context keeps a script's state for the next evaluation.
    expectValue("var x = 5; x * x", @"25");
    expectValue("x + 1", @"6");

    expectThrowsContaining("throw new Error('boom')", @"boom");
    expectThrowsContaining("function (", @"SyntaxError");
    expectThrowsContaining("nothingHere()", @"nothingHere");
    // The trace is all a script on a device has, so it must survive.
    NSString *trace = expectThrows("function inner() { throw new Error('deep'); }\ninner()");
    expect(!trace || [trace containsString:@"inner"], "the stack names the function that threw");
}

/// `source` evaluated with its output collected, expecting `value` back.
static NSString *expectOutput(const char *source, NSString *value) {
    NSString *output = nil;
    NSString *actual = evaluateCollecting(source, &output);
    if (actual) {
        expect([actual isEqualToString:value], "%s: expected %s, got %s",
               source, value.UTF8String, actual.UTF8String);
    }
    return output ?: @"";
}

static void outputCapture(void) {
    NSString *output = expectOutput("console.log('one', 2, {a: 3}); 'done'", @"done");
    expect([output isEqualToString:@"one 2 {\"a\":3}\n"], "console.log described each value: %s", output.UTF8String);
    output = expectOutput("console.error('to stderr'); 1", @"1");
    expect([output isEqualToString:@"to stderr\n"], "stderr is collected too: %s", output.UTF8String);
    output = expectOutput("2", @"2");
    expect([output isEqualToString:@""], "each evaluation collects only its own output: %s", output.UTF8String);
    // What the value's own toJSON prints while it is described belongs to
    // the same evaluation, or it would land on stdout beside the JSON line.
    output = expectOutput("({toJSON: function () { print('describing'); return 'x'; }})", @"\"x\"");
    expect([output isEqualToString:@"describing\n"], "describing the value is collected: %s", output.UTF8String);
    // An error collects what was printed before it.
    char *failure = NULL;
    char *printed = NULL;
    char *described = icli_probe_evaluate("print('before'); throw new Error('after')", &failure, &printed);
    expect(!described && failure && strstr(failure, "after"), "the error is reported: %s", failure ?: "");
    expect(printed && strcmp(printed, "before\n") == 0, "and the output before it kept: %s", printed ?: "(null)");
    free(described);
    free(failure);
    free(printed);

    // A runaway loop must not grow the buffer without bound: output stops at
    // 1 MiB, whether it comes as many lines or as one enormous write.
    output = expectOutput("for (var i = 0; i < 4000; i++) console.log('x'.repeat(1000)); 'capped'", @"capped");
    expect(output.length == 1u << 20, "many lines are capped at 1 MiB, were %lu", (unsigned long)output.length);
    output = expectOutput("console.log('x'.repeat(10 * 1024 * 1024)); 'capped'", @"capped");
    expect(output.length == 1u << 20, "one write is capped at 1 MiB, was %lu", (unsigned long)output.length);
    // The cut falls before a character it would split: half of an emoji's
    // surrogate pair would leave no UTF-8 to take at all.
    output = expectOutput("console.log('x'.repeat((1 << 20) - 1) + '\\u{1F600}'); 'capped'", @"capped");
    expect(strlen(output.UTF8String) == (1u << 20) - 1, "the cap keeps whole characters, kept %zu",
           strlen(output.UTF8String));

    // What a C string cannot carry, a lone surrogate (an emoji sliced in
    // half) or a NUL, becomes U+FFFD instead of losing the output, the value
    // or the error it lands in along with everything after it.
    output = expectOutput("console.log('kept'); console.log('\\ud83d'); console.log('a\\0b'); 'x\\0y'", @"x\uFFFDy");
    expect([output isEqualToString:@"kept\n\uFFFD\na\uFFFDb\n"], "the lines around them are kept: %s", output.UTF8String);
    expectValue("'\\ud83d\\ude00'.slice(0, 1)", @"\uFFFD");
    expectValue("'\\ud83d\\ude00'", @"\U0001F600");
    expectThrowsContaining("throw new Error('half \\ud83d')", @"half \uFFFD");
}

// MARK: - The ObjC Bridge

/// Live instances of IcliProbeTestObject, counted from allocation to
/// deallocation, so a test sees whether the bridge released exactly what it
/// owned: an over-release crashes under NSZombieEnabled, a leak stays counted.
/// The class also answers to the underscored names private methods have.
static int liveCounted;

@interface IcliProbeTestObject : NSObject
@end

@implementation IcliProbeTestObject

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    liveCounted++;
    return [super allocWithZone:zone];
}

/// An initializer that hands back another object and releases its receiver,
/// as a class cluster's does. Its leading underscore leaves it in the init
/// family, as it does the private initializers a probe calls.
- (instancetype)_initReplacingSelf {
    return [[IcliProbeTestObject alloc] init];
}

- (NSString *)_secret {
    return @"secret";
}

- (NSString *)_secretWith:(NSString *)suffix {
    return [@"secret " stringByAppendingString:suffix];
}

- (void)dealloc {
    liveCounted--;
}

@end

/// Make garbage until the collector has finalized what scripts dropped, or
/// give up after enough rounds that a leak is the only explanation left.
static void collectGarbage(void) {
    for (int round = 0; round < 40 && liveCounted > 0; round++) {
        @autoreleasepool {
            (void)evaluate("var junk = []; for (var i = 0; i < 200000; i++) junk.push({i: i}); junk = null");
        }
    }
}

static void bridgeOwnership(void) {
    // An object whose allocation is real, unlike NSString's or NSArray's
    // shared placeholder, which ignores retain and release and so hides a
    // miscount. alloc's handle and init's each own one reference.
    for (int round = 0; round < 20; round++) {
        @autoreleasepool {
            (void)evaluate("for (var i = 0; i < 100; i++) {"
                           "  ObjC.use('IcliProbeTestObject').alloc().init();"
                           "  ObjC.use('IcliProbeTestObject').alloc()._initReplacingSelf();"
                           "  ObjC.use('IcliProbeTestObject').new();"
                           "}");
        }
    }
    collectGarbage();
    expect(liveCounted == 0, "every initialized object was released exactly once, %d left", liveCounted);
}

static void bridgeBasics(void) {
    expectValue("typeof ObjC.use('NSProcessInfo')", @"object");
    expectValue("ObjC.use('NSProcessInfo').$isClass", @"true");
    expectThrowsContaining("ObjC.use('NoSuchClassHere')", @"No ObjC class");

    // A class method, then an instance method on what it returned.
    NSString *name = evaluate("ObjC.use('NSProcessInfo').processInfo().processName()");
    expect(name.length > 0, "processName returned a string: %s", name.UTF8String);
    expectValue("typeof ObjC.classes.NSProcessInfo.processInfo().processName()", @"string");

    // JSC's own types come back as themselves, not as handles.
    expectValue("ObjC.use('NSString').stringWithUTF8String_('hi')", @"hi");
    expectValue("typeof ObjC.use('NSString').stringWithUTF8String_('hi')", @"string");
    expectValue("ObjC.use('NSNumber').numberWithInt_(7) + 1", @"8");
    expectValue("typeof ObjC.use('NSNumber').numberWithBool_(true)", @"boolean");
    expectValue("ObjC.use('NSDate').dateWithTimeIntervalSince1970_(0) instanceof Date", @"true");
    expectValue("ObjC.use('NSNull').null()", @"null");

    // An object the bridge has to keep as a handle.
    expectValue("var list = ObjC.use('NSMutableArray').array(); list.count()", @"0");
    expectValue("list.addObject_('first'); list.addObject_('second'); list.count()", @"2");
    expectValue("list.objectAtIndex_(1)", @"second");
    expectValue("list.componentsJoinedByString_('-')", @"first-second");
    // A collection stays an object, and converts only when asked to.
    expectValue("list.$value.join(',')", @"first,second");
    expectValue("Array.isArray(list.$value)", @"true");
    expectValue("typeof list.$handle", @"object");
    expectValue("list.$class", @"__NSArrayM");

    // A leading underscore is part of a private method's name, not a colon.
    expectValue("ObjC.use('IcliProbeTestObject').new()._secret()", @"secret");
    expectValue("ObjC.use('IcliProbeTestObject').new()._secretWith_('kept')", @"secret kept");
    expectValue("ObjC.use('IcliProbeTestObject').new()._secretWith('bare')", @"secret bare");

    // A written-out selector, and an ObjC object as an argument.
    expectValue("var other = ObjC.use('NSMutableArray').array();"
                "other['addObjectsFromArray:'](list); other.count()",
                @"2");
    expectValue("var map = ObjC.use('NSMutableDictionary').dictionary();"
                "map.setValue_forKey_('v', 'k'); map.objectForKey_('k')",
                @"v");
    expectValue("JSON.stringify(map.$value)", @"{\"k\":\"v\"}");

    // Scalars in both directions.
    expectValue("ObjC.use('NSFileManager').defaultManager().fileExistsAtPath_('/')", @"true");
    expectValue("ObjC.use('NSFileManager').defaultManager().fileExistsAtPath_('/no/such/path')", @"false");
    expectValue("ObjC.use('NSString').stringWithUTF8String_('abc').length", @"3");

    // String conversion goes through the object's own description.
    expectValue("String(ObjC.use('NSMutableArray').array())", @"(\n)");

    // The alloc/init/copy families hand back an object the caller owns. Each
    // of these would over-release and take the process with it if the bridge
    // claimed ownership it had not been given, or leak if it missed one.
    expectValue("ObjC.use('NSMutableArray').alloc().init().count()", @"0");
    expectValue("ObjC.use('NSString').alloc()['initWithUTF8String:']('owned')", @"owned");
    expectValue("var copied = list.mutableCopy(); copied.addObject_('third'); copied.count()", @"3");
    expectValue("list.count()", @"2");
    expectValue("ObjC.use('NSMutableArray').array().copy().$class", @"__NSArray0");
}

static void bridgeRefusals(void) {
    expectThrowsContaining("ObjC.use('NSProcessInfo').processInfo().noSuchMethodAtAll()", @"does not respond to");
    // A bare NSProxy raises from the methods a bridge asks an object about;
    // it is still an object a script can hold, describe and ask about.
    expectThrowsContaining("ObjC.use('NSProxy').alloc().noSuchMethodAtAll()", @"does not respond to");
    expectValue("ObjC.use('NSProxy').alloc().self().$class", @"NSProxy");
    expectValue("ObjC.use('NSProxy').alloc().$value.indexOf('<NSProxy')", @"0");
    // A string with no UTF-8 form has no C form to pass.
    expectThrowsContaining("ObjC.use('NSString').stringWithUTF8String_('\\ud83d')", @"UTF-8 form");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_('a', 'b')", @"takes 1 argument");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_()", @"takes 1 argument");
    // A struct return would need its layout read out of the encoding; the
    // refusal has to name the type so the limit is obvious from the message.
    expectThrowsContaining("ObjC.use('NSProcessInfo').processInfo().operatingSystemVersion()", @"not supported");
    // Raising rather than crashing is the whole point of the @try around invoke.
    expectThrowsContaining("ObjC.use('NSMutableArray').array().objectAtIndex_(4)", @"raised");
    expectThrowsContaining("ObjC.use('NSMutableArray').array().addObject_(null)", @"raised");
    // A function is not a block; calling it as one would take the process.
    expectThrowsContaining("var a = ObjC.use('NSMutableArray').array(); a.addObject_('x');"
                           "a.enumerateObjectsUsingBlock_(function () {})",
                           @"block argument");
}

// MARK: - Files

static void files(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icli-probe-tests"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [directory stringByAppendingPathComponent:@"probe.txt"];

    NSString *source = [NSString stringWithFormat:@"fs.write('%@', 'written by the probe')", file];
    expectValue(source.UTF8String, @"20");
    source = [NSString stringWithFormat:@"fs.read('%@')", file];
    expectValue(source.UTF8String, @"written by the probe");
    source = [NSString stringWithFormat:@"fs.stat('%@').type", file];
    expectValue(source.UTF8String, @"file");
    source = [NSString stringWithFormat:@"fs.stat('%@').size", file];
    expectValue(source.UTF8String, @"20");
    source = [NSString stringWithFormat:@"fs.ls('%@').join(',')", directory];
    expectValue(source.UTF8String, @"probe.txt");
    (void)expectThrows("fs.read('/no/such/file/at/all')");
    (void)expectThrows("fs.ls('/no/such/directory')");
    expectThrowsContaining("fs.stat('/no/such/entry')", @"lstat(/no/such/entry)");
    // A path with no file-system form is an error, not a raise.
    expectThrowsContaining("fs.stat('')", @"Invalid argument");
    expectThrowsContaining("fs.stat('a\\0b')", @"Invalid argument");
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

// MARK: - The api() Handler

/// `echo` answers with the request itself, so a test sees what reached the
/// handler.
static char *answerAPI(const char *request) {
    if (strstr(request, "\"method\":\"boom\"")) {
        return strdup("{\"error\":{\"code\":\"invalid_operation\",\"message\":\"no\"}}");
    }
    if (strstr(request, "\"method\":\"echo\"")) {
        return strdup([NSString stringWithFormat:@"{\"result\":%s}", request].UTF8String);
    }
    return strdup("{\"result\":null}");
}

static void guestAPI(void) {
    // No handler is installed yet, so api() refuses before anything else.
    expectThrowsContaining("api('env.info')", @"no api handler");
    icli_probe_set_api_handler(answerAPI);
    expectValue("JSON.stringify(api('echo'))", @"{\"method\":\"echo\",\"params\":{}}");
    expectValue("JSON.stringify(api('echo', {with: 1}).params)", @"{\"with\":1}");
    // Params are encoded the way JavaScript encodes JSON: NaN and Infinity
    // become null and a Date its ISO string, where NSJSONSerialization would
    // raise and take the process with it. What JSON cannot hold throws.
    expectValue("JSON.stringify(api('echo', {n: NaN, i: Infinity, d: new Date(0)}).params)",
                @"{\"n\":null,\"i\":null,\"d\":\"1970-01-01T00:00:00.000Z\"}");
    expectThrowsContaining("var cycle = {}; cycle.self = cycle; api('echo', cycle)", @"cyclic");
    expectThrowsContaining("api('echo', [1, 2])", @"must be an object");
    expectThrowsContaining("api('boom')", @"invalid_operation");
    expectValue("api('other')", @"null");
    icli_probe_set_api_handler(NULL);
    expectThrowsContaining("api('again')", @"no api handler");
}

// MARK: - Deliberate Absences

static void absences(void) {
    // proc.run belongs to the host that spawns `icli probe`, not to icli, and
    // exit() would end the caller inline; neither is in the prelude.
    expectValue("typeof proc", @"undefined");
    expectValue("typeof exit", @"undefined");
    expectValue("typeof api", @"function");
    expectValue("typeof fs.read", @"function");
    expectValue("typeof ObjC.use", @"function");
}

// MARK: - Source Completeness

static void sourceCompleteness(void) {
    expect(!icli_probe_source_is_incomplete("1 + 1"), "a statement is complete");
    expect(!icli_probe_source_is_incomplete(""), "nothing is complete");
    expect(icli_probe_source_is_incomplete("function f() {"), "an open brace continues");
    expect(!icli_probe_source_is_incomplete("function f() {}"), "a closed brace does not");
    expect(icli_probe_source_is_incomplete("[1, 2,"), "an open bracket continues");
    expect(icli_probe_source_is_incomplete("f("), "an open call continues");
    expect(!icli_probe_source_is_incomplete("'a {'"), "a brace inside a string is text");
    expect(!icli_probe_source_is_incomplete("\"}\""), "and so is one in double quotes");
    expect(icli_probe_source_is_incomplete("`line"), "a template literal spans lines");
    expect(!icli_probe_source_is_incomplete("`line`"), "a closed one does not");
    expect(!icli_probe_source_is_incomplete("1 // {"), "a line comment ends at the newline");
    expect(icli_probe_source_is_incomplete("1 /* {"), "a block comment continues");
    expect(!icli_probe_source_is_incomplete("1 /* { */"), "a closed block comment does not");
    expect(!icli_probe_source_is_incomplete("'it\\'s'"), "an escaped quote stays inside the string");
    expect(!icli_probe_source_is_incomplete("}"), "a stray close brace is left to the parser");
    expect(!icli_probe_source_is_incomplete("/\\{/.test('{')"),
           "a brace inside a regular expression is not an open one");
    expect(!icli_probe_source_is_incomplete("var r = /['\"]/;"),
           "nor is a quote inside one the start of a string");
    expect(!icli_probe_source_is_incomplete("return /\\{/.test(s)"),
           "a regular expression may follow a keyword");
    expect(!icli_probe_source_is_incomplete("a / b / c"), "division is not a regular expression");
    expect(icli_probe_source_is_incomplete("var x = (a / b"),
           "an open call continues past a division");
    expect(icli_probe_source_is_incomplete("var r = /[{/"),
           "an unterminated regular expression is read as a division");
}

int main(void) {
    @autoreleasepool {
        runtimeBasics();
        outputCapture();
        bridgeBasics();
        bridgeOwnership();
        bridgeRefusals();
        files();
        guestAPI();
        absences();
        sourceCompleteness();
    }
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
