const std = @import("std");
const FP = @import("fp.zig").FP;

const permutation = [512]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225,
    140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148,
    247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,
    57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175,
    74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122,
    60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143, 54,
    65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169,
    200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,
    52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212,
    207, 206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213,
    119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104,
    218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241,
    81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157,
    184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,
    222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

const FInt = FP(32, 24, true);

pub fn noise3(x: FInt, y: FInt, z: FInt) FInt {
    const X = x.int() & 255;
    const Y = y.int() & 255;
    const Z = z.int() & 255;

    const xf = FInt{ .value = x.frac() };
    const yf = FInt{ .value = y.frac() };
    const zf = FInt{ .value = z.frac() };

    const u = fade(xf);
    const v = fade(yf);
    const w = fade(zf);

    const A = permutation[@intCast(X)] + Y;
    const AA = permutation[@intCast(A)] + Z;
    const AB = permutation[@intCast(A + 1)] + Z;
    const B = permutation[@intCast(X + 1)] + Y;
    const BA = permutation[@intCast(B)] + Z;
    const BB = permutation[@intCast(B + 1)] + Z;

    return lerp(
        w,
        lerp(
            v,
            lerp(
                u,
                grad(permutation[@intCast(AA)], xf, yf, zf),
                grad(permutation[@intCast(BA)], xf.sub(FInt.from(1)), yf, zf),
            ),
            lerp(
                u,
                grad(permutation[@intCast(AB)], xf, yf.sub(FInt.from(1)), zf),
                grad(permutation[@intCast(BB)], xf.sub(FInt.from(1)), yf.sub(FInt.from(1)), zf),
            ),
        ),
        lerp(
            v,
            lerp(
                u,
                grad(permutation[@intCast(AA + 1)], xf, yf, zf.sub(FInt.from(1))),
                grad(permutation[@intCast(BA + 1)], xf.sub(FInt.from(1)), yf, zf.sub(FInt.from(1))),
            ),
            lerp(
                u,
                grad(permutation[@intCast(AB + 1)], xf, yf.sub(FInt.from(1)), zf.sub(FInt.from(1))),
                grad(permutation[@intCast(BB + 1)], xf.sub(FInt.from(1)), yf.sub(FInt.from(1)), zf.sub(FInt.from(1))),
            ),
        ),
    );
}
fn fade(t: FInt) FInt {
    return t.mul(FInt.from(6)).sub(FInt.from(15)).mul(t).add(FInt.from(10)).mul(t).mul(t).mul(t);
}

fn lerp(t: FInt, a: FInt, b: FInt) FInt {
    return t.mul(b.sub(a)).add(a);
}

fn grad(hash: u8, x: FInt, y: FInt, z: FInt) FInt {
    const h = hash & 15;

    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;

    const p1 = if (h & 1 == 0) u else u.neg();
    const p2 = if (h & 2 == 0) v else v.neg();

    return p1.add(p2);
}
