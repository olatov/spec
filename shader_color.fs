#version 330

in vec2 fragTexCoord;
out vec4 finalColor;

uniform sampler2D texture0;
uniform float lines;          // Number of scanlines in the source image (e.g. 256)
uniform float curvature;      // Barrel distortion strength; higher = flatter (e.g. 6.0)

vec2 curveUV(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = uv.yx / curvature;
    uv += uv * offset * offset;
    return uv * 0.5 + 0.5;
}

void main() {
    vec2 uv = curveUV(fragTexCoord);

    // Outside the curved tube face - just black
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        finalColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec4 color = texture(texture0, uv);

    float brightness = dot(color.rgb, vec3(0.299, 0.587, 0.114));
    if (brightness < 0.05) {
        // A real tube never quite reaches pure black - leave a faint glow
        color.rgb = max(color.rgb, vec3(0.03));
    }

    // Smooth sinusoidal scanlines instead of a per-texel odd/even check,
    // so they hold up under the upscale from source lines to screen pixels
    float scan = 0.99 + 0.02 * cos(uv.y * lines * 3.14159265);
    color.rgb *= scan;

    // Aperture-grille style RGB phosphor mask, keyed to the source
    // texel grid (one R/G/B triad per emulated pixel) instead of raw
    // framebuffer pixels, so it looks the same at any output resolution.
    // A smooth wave instead of hard-edged stripes avoids moire beating
    // against the display/capture pixel grid, and fwidth() fades the
    // mask out if a texel ever shrinks below ~1 output pixel.
    float texelX = uv.x * float(textureSize(texture0, 0).x);
    float t = texelX * 6.28318530718;
    vec3 mask = 0.8 + 0.2 * cos(t - vec3(0.0, 2.09439510239, 4.18879020479));

    float aa = fwidth(t);
    float fade = clamp(1.0 - aa / 3.14159265, 0.0, 1.0);

    color.rgb *= mix(vec3(1.0), mask, 0.45 * fade);

    // Gentle vignette to darken the corners of the tube
    vec2 vc = uv - 0.5;
    color.rgb *= 1.0 - dot(vc, vc) * 0.5;

    finalColor = color;
}
