#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double width;
    double height;
    double scale;
    int orientation;
} IcliScreenMetrics;

/// Point dimensions of the upright interface and its fixed digitizer space.
/// Orientation is the clockwise rotation from fixed to upright, in degrees.
typedef struct {
    double width;
    double height;
    double reference_width;
    double reference_height;
    double scale;
    int orientation;
} IcliInterfaceGeometry;

bool icli_interface_geometry_valid(IcliInterfaceGeometry geometry);
/// Copies this thread's override, if present. Does not read the display.
bool icli_interface_geometry_current(IcliInterfaceGeometry *geometry);
/// Copies a validated override for this thread, or clears it when NULL.
/// Invalid input returns false and leaves the current override unchanged.
bool icli_interface_geometry_set(const IcliInterfaceGeometry *geometry);

IcliScreenMetrics icli_interface_geometry_metrics(IcliInterfaceGeometry geometry);
void icli_interface_geometry_point_to_fixed(IcliInterfaceGeometry geometry, double x, double y, double *fx, double *fy);
void icli_interface_geometry_fixed_to_point(IcliInterfaceGeometry geometry, double fx, double fy, double *x, double *y);
void icli_interface_geometry_point_to_digitizer(IcliInterfaceGeometry geometry, double x, double y, double *nx, double *ny);

#ifdef __cplusplus
}
#endif
