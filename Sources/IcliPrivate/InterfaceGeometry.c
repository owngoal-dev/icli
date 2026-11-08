#include "IcliInterfaceGeometry.h"
#include <math.h>
#include <stddef.h>

static _Thread_local bool hasOverride;
static _Thread_local IcliInterfaceGeometry currentOverride;

bool icli_interface_geometry_valid(IcliInterfaceGeometry geometry) {
    double dimensions[] = {geometry.width, geometry.height, geometry.reference_width, geometry.reference_height, geometry.scale};
    for (size_t i = 0; i < sizeof(dimensions) / sizeof(dimensions[0]); i++) {
        if (!isfinite(dimensions[i]) || dimensions[i] <= 0) return false;
    }
    if (geometry.orientation != 0 && geometry.orientation != 90 && geometry.orientation != 180 && geometry.orientation != 270) return false;
    bool sideways = geometry.orientation == 90 || geometry.orientation == 270;
    double width = sideways ? geometry.reference_height : geometry.reference_width;
    double height = sideways ? geometry.reference_width : geometry.reference_height;
    return fabs(geometry.width / width - 1) <= 1e-9 && fabs(geometry.height / height - 1) <= 1e-9;
}

bool icli_interface_geometry_current(IcliInterfaceGeometry *geometry) {
    if (!hasOverride) return false;
    if (geometry) *geometry = currentOverride;
    return true;
}

bool icli_interface_geometry_set(const IcliInterfaceGeometry *geometry) {
    if (geometry && !icli_interface_geometry_valid(*geometry)) return false;
    if (geometry) currentOverride = *geometry;
    hasOverride = geometry != NULL;
    return true;
}

IcliScreenMetrics icli_interface_geometry_metrics(IcliInterfaceGeometry geometry) {
    return (IcliScreenMetrics){geometry.width, geometry.height, geometry.scale, geometry.orientation};
}

void icli_interface_geometry_point_to_fixed(IcliInterfaceGeometry geometry, double x, double y, double *fx, double *fy) {
    switch (geometry.orientation) {
    case 90: *fx = y; *fy = geometry.reference_height - x; break;
    case 180: *fx = geometry.reference_width - x; *fy = geometry.reference_height - y; break;
    case 270: *fx = geometry.reference_width - y; *fy = x; break;
    default: *fx = x; *fy = y; break;
    }
}

void icli_interface_geometry_fixed_to_point(IcliInterfaceGeometry geometry, double fx, double fy, double *x, double *y) {
    switch (geometry.orientation) {
    case 90: *x = geometry.reference_height - fy; *y = fx; break;
    case 180: *x = geometry.reference_width - fx; *y = geometry.reference_height - fy; break;
    case 270: *x = fy; *y = geometry.reference_width - fx; break;
    default: *x = fx; *y = fy; break;
    }
}

void icli_interface_geometry_point_to_digitizer(IcliInterfaceGeometry geometry, double x, double y, double *nx, double *ny) {
    double fx, fy;
    icli_interface_geometry_point_to_fixed(geometry, x, y, &fx, &fy);
    *nx = fx / geometry.reference_width;
    *ny = fy / geometry.reference_height;
}
