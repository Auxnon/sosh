uniform vec3 color;
varying vec3 vColor;
varying vec4 vPos;
varying vec4 vNormal;
varying vec2 vUv;
uniform bool billboard;
uniform float scale;

void main() {
    vColor = color;
    vUv = uv;
    if(billboard) {
        vPos = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    } else {
        vPos = projectionMatrix * modelViewMatrix * vec4(position + normal * scale, 1.0);
    }

    vNormal = vec4(normal, 1.0);

    if(billboard) {
        vPos += vec4((modelMatrix * vec4(normal * scale, 0.0)).xy, 0., 0.); // better
    }

    gl_Position = vPos;
}
