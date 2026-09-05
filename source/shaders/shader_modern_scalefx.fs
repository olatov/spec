#version 330

in vec2 fragTexCoord;
out vec4 finalColor;

uniform sampler2D texture0;

// Single-pass edge-directed upscaler in the spirit of scaleFX / Scale2x -
// the "advanced interpolation" family (DOSBox advinterp / advmame, HQx).
//
// Faithful scaleFX is a four-pass shader: build an edge map, detect
// corners, merge corner candidates, then interpolate. Collapsed into one
// pass we keep the two parts that matter for Spectrum art:
//
//   * neighbours are compared by perceptual colour distance, not exact
//     equality, so softened or lightly dithered pixels count as "similar";
//   * a diagonal is only bent when the opposite pair agrees with itself
//     (the classic B!=H && D!=F guard), which leaves checkerboard dither -
//     very common for Spectrum shading - completely untouched.
//
// The four Scale2x corner decisions are then cross-faded with an fwidth()
// band so edges come out anti-aliased instead of a bigger staircase.
//
// Expects texture0 (the render target) sampled 1:1 with the emulated
// frame and with point filtering - the app sets that for this TV type.

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

float cdist(vec3 a, vec3 b) {
    vec3 d = a - b;
    return dot(d * d, vec3(1.0)) + abs(dot(d, LUMA));
}

bool near(vec3 a, vec3 b) {
    return cdist(a, b) < 0.025;
}

void main() {
    vec2 ts = vec2(textureSize(texture0, 0));
    vec2 tx = 1.0 / ts;

    vec2 coord = fragTexCoord * ts - 0.5;
    vec2 base  = floor(coord);
    vec2 f     = coord - base;              // sub-texel position, [0,1)
    vec2 uv    = (base + 0.5) * tx;         // centre of texel E

    vec3 B = texture(texture0, uv + tx * vec2( 0.0, -1.0)).rgb;
    vec3 D = texture(texture0, uv + tx * vec2(-1.0,  0.0)).rgb;
    vec3 E = texture(texture0, uv).rgb;
    vec3 F = texture(texture0, uv + tx * vec2( 1.0,  0.0)).rgb;
    vec3 H = texture(texture0, uv + tx * vec2( 0.0,  1.0)).rgb;

    vec3 e0 = E, e1 = E, e2 = E, e3 = E;    // TL, TR, BL, BR sub-pixels

    // Only reshape where a clean edge crosses the texel - not inside a
    // gradient and not through checkerboard dither.
    if (!near(B, H) && !near(D, F)) {
        if (near(D, B)) e0 = mix(D, B, 0.5);
        if (near(B, F)) e1 = mix(B, F, 0.5);
        if (near(D, H)) e2 = mix(D, H, 0.5);
        if (near(H, F)) e3 = mix(H, F, 0.5);
    }

    // Cross-fade the four decisions with a ~1 output-pixel wide band.
    vec2 aa = fwidth(coord) * 0.5 + 1e-4;
    vec2 w  = smoothstep(0.5 - aa, 0.5 + aa, f);

    vec3 top = mix(e0, e1, w.x);
    vec3 bot = mix(e2, e3, w.x);
    finalColor = vec4(mix(top, bot, w.y), 1.0);
}
