import * as THREE from 'three';

interface VoxelMeshParams {
  data: number[];
  width: number;
  height: number;
  depth: number;
  bevelRadius?: number;
}

export class VoxelMesh {
  private geometry: THREE.BufferGeometry;
  private material: THREE.ShaderMaterial;
  private mesh: THREE.Mesh;

  constructor({ data, width, height, depth, bevelRadius = 0.1 }: VoxelMeshParams) {
    // Create a simple plane geometry that covers the screen
    this.geometry = new THREE.PlaneGeometry(2, 2);

    // Define the shader material
    this.material = new THREE.ShaderMaterial({
      uniforms: {
        voxelData: { value: new THREE.DataTexture(
          new Float32Array(data),
          width,
          height * depth,
          THREE.RedFormat,
          THREE.FloatType
        ) },
        dimensions: { value: new THREE.Vector3(width, height, depth) },
        bevelRadius: { value: bevelRadius },
        topColor: { value: new THREE.Color(0x63B05D) },  // Minecraft grass green
        bottomColor: { value: new THREE.Color(0x8B5E34) },  // Minecraft dirt brown
      },
      vertexShader: `
        varying vec2 vUv;
        void main() {
          vUv = uv;
          gl_Position = vec4(position, 1.0);
        }
      `,
      fragmentShader: `
        uniform sampler2D voxelData;
        uniform vec3 dimensions;
        uniform float bevelRadius;
        uniform vec3 topColor;
        uniform vec3 bottomColor;
        varying vec2 vUv;

        float sampleVoxel(vec3 p) {
          if (p.x < 0.0 || p.x >= dimensions.x ||
              p.y < 0.0 || p.y >= dimensions.y ||
              p.z < 0.0 || p.z >= dimensions.z) return 0.0;
              
          float index = p.x + dimensions.x * (p.z + dimensions.z * p.y);
          vec2 uv = vec2(
            mod(index, dimensions.x) / dimensions.x,
            floor(index / dimensions.x) / (dimensions.y * dimensions.z)
          );
          return texture2D(voxelData, uv).r;
        }

        float sdBox(vec3 p, vec3 b) {
          vec3 q = abs(p) - b;
          return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
        }

        vec2 rayMarch(vec3 ro, vec3 rd) {
          float t = 0.0;
          float voxelId = 0.0;
          
          for(int i = 0; i < 128; i++) {
            vec3 p = ro + rd * t;
            vec3 cell = floor(p);
            
            float currentVoxel = sampleVoxel(cell);
            if(currentVoxel > 0.0) {
              vec3 localP = fract(p) - 0.5;
              float d = sdBox(localP, vec3(0.5 - bevelRadius));
              d -= bevelRadius;
              
              if(d < 0.001) {
                voxelId = currentVoxel;
                break;
              }
            }
            
            t += 0.1;
            if(t > 100.0) break;
          }
          
          return vec2(t, voxelId);
        }

        void main() {
          vec2 uv = vUv * 2.0 - 1.0;
          
          // Setup camera ray
          vec3 ro = vec3(dimensions.x * 0.5, dimensions.y * 1.2, dimensions.z * 2.0);
          vec3 rd = normalize(vec3(uv.x, uv.y - 0.5, -1.0));
          
          vec2 result = rayMarch(ro, rd);
          float t = result.x;
          float voxelId = result.y;
          
          if(voxelId > 0.0) {
            vec3 p = ro + rd * t;
            // Blend between top and bottom colors based on height
            float heightBlend = smoothstep(0.0, dimensions.y, p.y);
            vec3 color = mix(bottomColor, topColor, heightBlend);
            
            // Simple lighting
            float light = max(0.2, dot(normalize(vec3(1.0, 1.0, 0.5)), rd));
            gl_FragColor = vec4(color * light, 1.0);
          } else {
            gl_FragColor = vec4(0.0, 0.0, 0.0, 0.0);
          }
        }
      `,
      transparent: true,
    });

    this.mesh = new THREE.Mesh(this.geometry, this.material);
  }

  getMesh(): THREE.Mesh {
    return this.mesh;
  }

  update(newData: number[]): void {
    const texture = this.material.uniforms.voxelData.value as THREE.DataTexture;
    texture.image.data.set(newData);
    texture.needsUpdate = true;
  }

  dispose(): void {
    this.geometry.dispose();
    this.material.dispose();
  }
}
