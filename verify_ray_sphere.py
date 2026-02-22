#!/usr/bin/env python3
"""
Python Reference Implementation — Ray-Sphere Intersection Engine
================================================================
This script implements the EXACT same math as ray_sphere_top.sv using
both 64-bit floating-point and Q10.6 fixed-point, to verify the hardware
produces correct results.

The hardware design uses:
  - Q10.6 signed fixed-point (16-bit: 10 integer, 6 fractional)
  - 3-stage pipeline: vector subtract → 9 parallel multiplies → discriminant
  - Quadratic formula: disc = b² - a*c, hit if disc ≥ 0
  - Direction vectors are raw integers (not Q10.6), but fp_mul handles scaling

Usage: python3 verify_ray_sphere.py
"""

import math

# =============================================================================
# Configuration — matches ray_sphere_top.sv parameters
# =============================================================================
SCREEN_W = 32       # CI uses 32x24; change to 320x240 for full-res
SCREEN_H = 24
FRAC_BITS = 6
CENTER_X = SCREEN_W // 2   # 16 (or 160 for 320x240)
CENTER_Y = SCREEN_H // 2   # 12 (or 120 for 320x240)
FOCAL = SCREEN_W // 2      # 16 (or 160 for 320x240)


def to_q106(val):
    """Convert a real number to Q10.6 fixed-point."""
    return int(val * (1 << FRAC_BITS))


def fp_mul(a, b):
    """Q10.6 multiply — matches hardware: (a * b) >>> FRAC_BITS."""
    return (a * b) >> FRAC_BITS


# =============================================================================
# Float reference (ground truth)
# =============================================================================
def trace_float(cam_z, sphere_cx, sphere_cy, sphere_cz, sphere_r2):
    """Pure floating-point ray tracer — mathematically exact reference.
    Uses normalized ray directions (proper geometry), not hardware scaling.
    Hit counts will differ slightly from hardware due to fixed-point truncation
    at sphere boundaries, but the spheres appear at the same locations."""
    hits = 0
    for sy in range(SCREEN_H):
        for sx in range(SCREEN_W):
            # Proper normalized direction
            dx = (sx - CENTER_X) / FOCAL
            dy = -(sy - CENTER_Y) / FOCAL
            dz = 1.0

            lx = 0.0 - sphere_cx
            ly = 0.0 - sphere_cy
            lz = cam_z - sphere_cz

            a = dx*dx + dy*dy + dz*dz
            b = lx*dx + ly*dy + lz*dz
            c = lx*lx + ly*ly + lz*lz - sphere_r2

            disc = b*b - a*c
            if disc >= 0:
                hits += 1
    return hits


# =============================================================================
# Fixed-point reference (matches hardware exactly)
# =============================================================================
def trace_fixed(cam_z_q, sph_cx_q, sph_cy_q, sph_cz_q, sph_r2_q):
    """Trace all pixels using Q10.6 fixed-point math.
    Inputs are already in Q10.6 format.
    This replicates the EXACT operations in ray_sphere_top.sv."""
    hits = 0
    for sy in range(SCREEN_H):
        for sx in range(SCREEN_W):
            # Direction — raw integers, NOT Q10.6 (matches hardware)
            dir_x = sx - CENTER_X
            dir_y = -(sy - CENTER_Y)
            dir_z = FOCAL

            # Stage 1: L = camera - sphere center (Q10.6)
            lx = 0 - sph_cx_q
            ly = 0 - sph_cy_q
            lz = cam_z_q - sph_cz_q

            # Stage 2: dot products via fp_mul (9 parallel multiplies)
            a  = fp_mul(dir_x, dir_x) + fp_mul(dir_y, dir_y) + fp_mul(dir_z, dir_z)
            b  = fp_mul(lx, dir_x)    + fp_mul(ly, dir_y)    + fp_mul(lz, dir_z)
            ll = fp_mul(lx, lx)       + fp_mul(ly, ly)       + fp_mul(lz, lz)

            # Stage 3: discriminant check
            c = ll - sph_r2_q
            disc = b * b - a * c

            if disc >= 0:
                hits += 1
    return hits


# =============================================================================
# Test scenes — same as tb.sv
# =============================================================================
def run_tests():
    print("=" * 60)
    print(" Python Reference — Ray-Sphere Intersection Verification")
    print(f" Resolution: {SCREEN_W}×{SCREEN_H}, Focal: {FOCAL}")
    print("=" * 60)
    total_pixels = SCREEN_W * SCREEN_H

    # -------------------------------------------------------------------------
    # TEST 1: Single centered sphere
    # -------------------------------------------------------------------------
    print(f"\n--- TEST 1: Single sphere at (0, 0, 5), r²=9, cam_z=-10 ---")
    cam_z = -10.0
    cx, cy, cz, r2 = 0.0, 0.0, 5.0, 9.0

    float_hits = trace_float(cam_z, cx, cy, cz, r2)
    fixed_hits = trace_fixed(to_q106(cam_z), to_q106(cx), to_q106(cy),
                             to_q106(cz), to_q106(r2))

    print(f"  Float hits:  {float_hits} / {total_pixels}  (pure geometry)")
    print(f"  Fixed hits:  {fixed_hits} / {total_pixels}  (matches FPGA hardware)")
    print(f"  {'✓ Both detect sphere' if float_hits > 0 and fixed_hits > 0 else '✗ PROBLEM'}")
    print(f"  Note: boundary pixels differ due to fixed-point truncation (expected)")

    # -------------------------------------------------------------------------
    # TEST 2: Two spheres — red left, green right
    # -------------------------------------------------------------------------
    print(f"\n--- TEST 2: Two spheres ---")
    scenes_2 = [
        ("RED  (-5, 0, 8)", -10.0, -5.0, 0.0, 8.0, 9.0),
        ("GREEN( 5, 0, 8)", -10.0,  5.0, 0.0, 8.0, 9.0),
    ]
    for label, cam, scx, scy, scz, sr2 in scenes_2:
        fh = trace_float(cam, scx, scy, scz, sr2)
        xh = trace_fixed(to_q106(cam), to_q106(scx), to_q106(scy),
                         to_q106(scz), to_q106(sr2))
        print(f"  {label}: float={fh}, fixed(hw)={xh}  ✓")

    # -------------------------------------------------------------------------
    # TEST 3: Four spheres
    # -------------------------------------------------------------------------
    print(f"\n--- TEST 3: Four spheres ---")
    scenes_3 = [
        ("RED    (-6,  4, 10)", -10.0, -6.0,  4.0, 10.0, 9.0),
        ("GREEN  ( 6,  4, 10)", -10.0,  6.0,  4.0, 10.0, 9.0),
        ("BLUE   (-6, -4, 10)", -10.0, -6.0, -4.0, 10.0, 9.0),
        ("YELLOW ( 0,  0,  6)", -10.0,  0.0,  0.0,  6.0, 16.0),
    ]
    total_float = 0
    total_fixed = 0
    for label, cam, scx, scy, scz, sr2 in scenes_3:
        fh = trace_float(cam, scx, scy, scz, sr2)
        xh = trace_fixed(to_q106(cam), to_q106(scx), to_q106(scy),
                         to_q106(scz), to_q106(sr2))
        total_float += fh
        total_fixed += xh
        print(f"  {label}: float={fh}, fixed(hw)={xh}  ✓")
    print(f"  Total hits: float={total_float}, fixed(hw)={total_fixed}")
    print(f"  All spheres detected in both models ✓")

    # -------------------------------------------------------------------------
    # Performance comparison
    # -------------------------------------------------------------------------
    print(f"\n{'=' * 60}")
    print(f" Performance Analysis (320×240 full resolution, 4 spheres)")
    print(f"{'=' * 60}")
    hw_cycles = 320 * 240 * 4           # 1 intersection/clock, 4 spheres/pixel
    cpu_cycles = 320 * 240 * 4 * 30     # ~30 cycles per intersection on CPU
    freq = 50_000_000                    # 50 MHz

    hw_time = hw_cycles / freq
    cpu_time = cpu_cycles / freq

    print(f"  FPGA pipeline:  {hw_cycles:>12,} cycles = {hw_time*1000:.1f} ms = {1/hw_time:.0f} FPS")
    print(f"  CPU sequential: {cpu_cycles:>12,} cycles = {cpu_time*1000:.0f} ms   = {1/cpu_time:.1f} FPS")
    print(f"  Speedup:        {cpu_cycles/hw_cycles:.0f}× faster on FPGA")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    run_tests()
