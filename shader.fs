#version 330

in vec2 fragTexCoord;
out vec4 finalColor;

uniform sampler2D texture0;
uniform int enableGrayscale;
uniform int enableScanlines;
uniform float lines;          // Number of vertical lines (e.g. 200)

void main() {
    vec4 color = texture(texture0, fragTexCoord);

    float brightness = dot(color.rgb, vec3(0.299, 0.587, 0.114));

    if (enableGrayscale != 0) {
        float gray = dot(color.rgb, vec3(0.263, 0.678, 0.059));
        color.rgb = vec3(gray);
    }

    if (enableScanlines != 0) {
        float y = fragTexCoord.y * lines;

        if (brightness < 0.05) {
            // For pure black, add a bit of "noise" glow
            color.rgb = vec3(0.05);
        } else         

        // If even line, darken
        if (int(floor(y)) % 2 == 0) {
            color.rgb *= 0.9925; // 0.992;
        }        
    }

    finalColor = color;
}
