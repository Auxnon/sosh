import * as THREE from 'three';

interface VoxelMeshParams {
  data: number[];
  width: number;
  height: number;
  depth: number;
  isolevel?: number;
}

// Lookup tables for marching cubes
const EDGE_TABLE = new Int32Array([
  0x0, 0x109, 0x203, 0x30a, 0x406, 0x50f, 0x605, 0x70c,
  0x80c, 0x905, 0xa0f, 0xb06, 0xc0a, 0xd03, 0xe09, 0xf00,
  // ... (truncated for brevity - in practice you'd include the full table)
]);

const TRI_TABLE = new Int32Array([
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  0, 8, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
  // ... (truncated for brevity - in practice you'd include the full table)
]);

export class VoxelMesh {
  private geometry: THREE.BufferGeometry;
  private material: THREE.MeshPhongMaterial;
  private mesh: THREE.Mesh;

  constructor({ data, width, height, depth, isolevel = 0.5 }: VoxelMeshParams) {
    const vertices: number[] = [];
    const normals: number[] = [];
    const colors: number[] = [];
    const indices: number[] = [];

    // Helper function to get data at position
    const getValue = (x: number, y: number, z: number): number => {
      if (x < 0 || x >= width || y < 0 || y >= height || z < 0 || z >= depth) {
        return 0;
      }
      return data[x + width * (z + depth * y)];
    };

    // Process each cell
    for (let y = 0; y < height - 1; y++) {
      for (let z = 0; z < depth - 1; z++) {
        for (let x = 0; x < width - 1; x++) {
          // Get the values at the corners of the cube
          const cubeValues = [
            getValue(x, y, z),
            getValue(x + 1, y, z),
            getValue(x + 1, y, z + 1),
            getValue(x, y, z + 1),
            getValue(x, y + 1, z),
            getValue(x + 1, y + 1, z),
            getValue(x + 1, y + 1, z + 1),
            getValue(x, y + 1, z + 1),
          ];

          // Determine which edges are intersected
          let cubeIndex = 0;
          for (let i = 0; i < 8; i++) {
            if (cubeValues[i] > isolevel) {
              cubeIndex |= 1 << i;
            }
          }

          // Skip if cube is entirely inside or outside
          if (EDGE_TABLE[cubeIndex] === 0) continue;

          // Calculate vertex positions for each intersected edge
          const vertList: THREE.Vector3[] = [];
          for (let i = 0; i < 12; i++) {
            if (EDGE_TABLE[cubeIndex] & (1 << i)) {
              const v1 = new THREE.Vector3();
              const v2 = new THREE.Vector3();
              
              // Get edge vertices
              switch (i) {
                case 0: v1.set(x, y, z); v2.set(x + 1, y, z); break;
                case 1: v1.set(x + 1, y, z); v2.set(x + 1, y, z + 1); break;
                // ... (other edge cases)
              }

              // Interpolate position
              const val1 = getValue(Math.floor(v1.x), Math.floor(v1.y), Math.floor(v1.z));
              const val2 = getValue(Math.floor(v2.x), Math.floor(v2.y), Math.floor(v2.z));
              const t = (isolevel - val1) / (val2 - val1);
              
              vertList[i] = v1.lerp(v2, t);
            }
          }

          // Create triangles
          for (let i = 0; TRI_TABLE[cubeIndex * 16 + i] !== -1; i += 3) {
            const idx1 = TRI_TABLE[cubeIndex * 16 + i];
            const idx2 = TRI_TABLE[cubeIndex * 16 + i + 1];
            const idx3 = TRI_TABLE[cubeIndex * 16 + i + 2];

            const v1 = vertList[idx1];
            const v2 = vertList[idx2];
            const v3 = vertList[idx3];

            // Add vertex positions
            vertices.push(v1.x, v1.y, v1.z);
            vertices.push(v2.x, v2.y, v2.z);
            vertices.push(v3.x, v3.y, v3.z);

            // Calculate normal
            const normal = new THREE.Vector3()
              .crossVectors(
                new THREE.Vector3().subVectors(v2, v1),
                new THREE.Vector3().subVectors(v3, v1)
              )
              .normalize();

            // Add normals
            normals.push(normal.x, normal.y, normal.z);
            normals.push(normal.x, normal.y, normal.z);
            normals.push(normal.x, normal.y, normal.z);

            // Add colors (gradient from bottom to top)
            const topColor = new THREE.Color(0x63B05D);  // Minecraft grass green
            const bottomColor = new THREE.Color(0x8B5E34);  // Minecraft dirt brown
            
            [v1, v2, v3].forEach(v => {
              const heightBlend = Math.max(0, Math.min(1, v.y / height));
              const color = new THREE.Color().lerpColors(bottomColor, topColor, heightBlend);
              colors.push(color.r, color.g, color.b);
            });

            // Add indices
            const baseIndex = indices.length;
            indices.push(baseIndex, baseIndex + 1, baseIndex + 2);
          }
        }
      }
    }

    // Create geometry
    this.geometry = new THREE.BufferGeometry();
    this.geometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
    this.geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
    this.geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
    this.geometry.setIndex(indices);

    // Create material
    this.material = new THREE.MeshPhongMaterial({
      vertexColors: true,
      flatShading: true
    });

    // Create mesh
    this.mesh = new THREE.Mesh(this.geometry, this.material);
  }

  getMesh(): THREE.Mesh {
    return this.mesh;
  }

  dispose(): void {
    this.geometry.dispose();
    this.material.dispose();
  }
}
