import { Vector3 } from "three";
import * as three from "three";
import { OrbitControls, type Vector } from "three/examples/jsm/Addons.js";
// import { OrbitControls } from "three/examples/jsm/controls/OrbitControls";

export function create(element: HTMLCanvasElement, pointSet: (point: Vector3) => void): void {
  console.log("create");

  let WARP = false;
  let BILLBOARD = false;
  let SNAP = true;

  const scene = new three.Scene();
  const root = new three.Group();
  root.position.set(0, -5, 0);
  scene.add(root);
  const cam = new three.PerspectiveCamera(75, element.clientWidth / element.clientHeight, 0.1, 1000);

  const renderer = new three.WebGLRenderer({ canvas: element, alpha: false });
  renderer.setSize(element.clientWidth, element.clientHeight);
  renderer.setClearColor(0xc6eff7, 1);

  const controls = new OrbitControls(cam, renderer.domElement);

  const raycaster = new three.Raycaster();
  const pointer = new three.Vector2();
  let ribbon: three.Mesh;
  let ribbonMaterial: three.ShaderMaterial;

  const cube = (c: number) => {
    const geometry = new three.BoxGeometry();
    const material = new three.MeshBasicMaterial({ color: c });
    const cub = new three.Mesh(geometry, material);
    root.add(cub);
    return cub;
  };
  cube(0xff00ff);
  cube(0xff0000).position.set(1, 0, 0);
  cube(0x00ff00).position.set(0, 1, 0);
  cube(0x0000ff).position.set(0, 0, 1);
  const mover = cube(0x00ffff);
  mover.scale.set(0.01, 0.01, 0.01);

  const gridHelper1 = new three.GridHelper(10, 10);
  const gridHelper2 = gridHelper1.clone();
  const gridHelper3 = gridHelper1.clone();

  gridHelper2.position.y = 5;
  gridHelper2.position.x = 5;
  gridHelper2.rotation.z = Math.PI / 2;

  gridHelper3.rotation.x = Math.PI / 2;
  gridHelper3.position.y = 5;
  gridHelper3.position.z = 5;

  root.add(gridHelper1);
  root.add(gridHelper2);
  root.add(gridHelper3);

  cam.position.z = 20;

  /// BLUE

  const { texture, array } = createTexture();

  const divisor = 1 / array.length;
  {
    // curve
    const curve = new three.CatmullRomCurve3([
      new three.Vector3(0, 10, 0),
      new three.Vector3(0.4, 8, 0.1),
      new three.Vector3(1.2, 6, -3),
      new three.Vector3(0.1, 4, -4),
      new three.Vector3(-1, 2, -7),
      new three.Vector3(-0.6, 0, -12),
    ]);

    const points = curve.getPoints(50);
    //  geometry.attributes.position.itemSize
    const size = points.length * 2;
    const verts: three.Vector3[] = new Array(size);
    const indices = new Array((points.length - 1) * 6);
    const norms: three.Vector3[] = new Array(size);
    const uvs = new Array(size);
    for (let i = 0; i < points.length; i++) {
      const v2 = points[i].clone();
      v2.x -= 1;
      const c = i * 2;
      const d = i * 2 + 1;

      verts[c] = points[i];
      verts[d] = v2;
      if (i > 0) {
        // perpendicular
        const perp = points[i]
          .clone()
          .sub(points[i - 1])
          .normalize()
          .cross(new three.Vector3(0, 0, -1));
        perp.y = 0;
        perp.normalize();
        // A B
        // C D
        const a = c - 2;
        const b = d - 2;
        const ii = i * 6;
        // tri 1 ABC
        indices[ii] = a;
        indices[ii + 1] = b;
        indices[ii + 2] = d;
        // tri 2 DCB
        indices[ii + 3] = d;
        indices[ii + 4] = c;
        indices[ii + 5] = a;

        norms[c] = new three.Vector3();
        norms[d] = perp;
        const u = i / points.length;
        uvs[c] = new three.Vector2(u, 0);
        uvs[d] = new three.Vector2(u, 1);
      }
    }
    norms[norms.length - 2] = norms[norms.length - 3];
    norms[norms.length - 1] = norms[norms.length - 2];
    uvs[uvs.length - 2] = uvs[uvs.length - 3];
    uvs[uvs.length - 1] = uvs[uvs.length - 2];

    const geometry = new three.BufferGeometry().setFromPoints(verts);
    geometry.setIndex(indices);

    const vs = verts.flatMap((v) => [v.x, v.y, v.z]);
    geometry.setAttribute("position", new three.Float32BufferAttribute(vs, 3));

    const ns = norms.flatMap((v) => [v.x, v.y, v.z]);
    geometry.setAttribute("normal", new three.Float32BufferAttribute(ns, 3));

    const us = uvs.flatMap((v) => [v.x, v.y]);
    geometry.setAttribute("uv", new three.Float32BufferAttribute(us, 2));

    const colors = [0x7c00db, 0x0644e9, 0x16ac25, 0xfefa01, 0xf5bd02];
    const ramp = createColorRamp(colors);

    ribbonMaterial = new three.ShaderMaterial({
      uniforms: {
        color: { value: new three.Color(0x00ff00) },
        tex: {
          value: texture,
        },
        ramp: {
          value: ramp,
        },
        highlight: { value: 0.5 },
        divisor: { value: divisor / 2 },
        billboard: { value: BILLBOARD },
      },
      vertexShader: `
        uniform vec3 color;
        varying vec3 vColor;
        varying vec4 vPos;
        // attribute vec3 normal;
        varying vec4 vNormal;
        varying vec2 vUv;
        uniform bool billboard;


        void main() {
            vColor = color;
            vUv = uv;
            vPos = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
            // vPos+=  3.*vec4(normal.x,normal.y, normal.z, 1.0) * projectionMatrix ;
            vNormal =  vec4(normal, 1.0);
             


            if (billboard) {
              vPos+=  6.*vec4(normal, 1.0) *modelMatrix  ;
            }
            gl_Position = vPos;
        }
      `,
      fragmentShader: `
        varying vec3 vColor;
        varying vec4 vPos;
        varying vec4 vNormal;
        varying vec2 vUv;
        uniform mediump usampler2D tex;
        uniform usampler2D ramp;
        uniform float highlight;
        uniform float divisor;
        void main() {
          // vec2 vCoords = vPos.xy;
          // vCoords /= vPos.w;
          // vCoords = vCoords * 0.5 + 0.5;
          // vec2 uv = fract( vCoords * 10.0 );

          // if between highlight minus 0.1 and highlight plus 0.1

          uint p = texture(tex, vUv).r;
          float f = float(p) / 255.0;
          uvec4 c = texture(ramp, vec2(f, 0.5));
          if (f < vUv.y) {
            discard;
          } else {
           
          vec4 final = vec4(float(c.r) / 255.0, float(c.g) / 255.0, float(c.b) / 255.0, 1.0);
          float v1= highlight - 7.*divisor;
          float v2= highlight -divisor;
          float v3= highlight +divisor;
        float v4= highlight + 7.*divisor;
          if (vUv.x > v1 && vUv.x < v2 || vUv.x > v3 && vUv.x < v4) {
           final /= 4.0;

          }
          gl_FragColor  = final;
          }
          
        }
      `,
      side: three.DoubleSide,
    });

    // Create the final object to add to the scene
    const mesh = new three.Mesh(geometry, ribbonMaterial);
    ribbon = mesh;

    // YELLOW

    const simpleGeometry = new three.BufferGeometry().setFromPoints(points);
    const simpleMaterial = new three.LineBasicMaterial({ color: 0xff0000, linewidth: 1 });
    const simple = new three.Line(simpleGeometry, simpleMaterial);
    root.add(simple);
    root.add(mesh);
  }

  function animate() {
    requestAnimationFrame(animate);
    // root.rotation.x += 0.01;
    // root.rotation.y += 0.01;
    // array.set

    if (WARP) {
      warpArray(array);
      texture.needsUpdate = true;
    }

    controls.update();

    raycaster.setFromCamera(pointer, cam);
    const intersects = raycaster.intersectObjects([ribbon], true);
    if (intersects.length > 0) {
      const inter = intersects[0];

      const p = inter.point;
      let value = 0;
      if (inter.uv) {
        let index;
        if (SNAP) {
          index = -divisor / 2 + Math.floor((inter.uv.x + divisor) * array.length) / array.length;
        } else {
          index = inter.uv.x;
        }

        value = array[Math.floor(index * array.length)];

        ribbonMaterial.uniforms.highlight.value = index;
      }
      pointSet(new Vector3(inter.uv?.x || 0, inter.uv?.y || 0, value));
      mover.position.x = p.x;
      mover.position.y = p.y + 5;
      mover.position.z = p.z;
      // mover.position.y += 0.02;
      // intersects[0].point
    }
    renderer.render(scene, cam);
  }

  window.addEventListener("pointermove", (e) => {
    pointer.x = (e.clientX / window.innerWidth) * 2 - 1;
    pointer.y = -(e.clientY / window.innerHeight) * 2 + 1;
  });
  window.addEventListener("keydown", (e) => {
    if (e.key === " ") {
      WARP = !WARP;
    } else if (e.key === "b") {
      BILLBOARD = !BILLBOARD;
      ribbonMaterial.uniforms.billboard.value = BILLBOARD;
    } else if (e.key === "s") {
      SNAP = !SNAP;
    }
  });

  animate();
}

function createTexture(): { texture: three.DataTexture; array: Uint8Array } {
  const uintSize = 1024;
  const uintArray = new Uint8Array(uintSize);
  warpArray(uintArray);
  const texture = new three.DataTexture(uintArray, uintSize, 1, three.RedIntegerFormat, three.UnsignedByteType);
  // texture.internalFormat = "RGBA8UI";
  texture.internalFormat = "R8UI";
  // texture.magFilter = three.NearestFilter;
  texture.needsUpdate = true;

  return { texture, array: uintArray };
}

function warpArray(array: Uint8Array): void {
  let r = 0;
  for (let j = 0; j < array.length; j++) {
    r += Math.random() * 0.1;
    let d = Math.abs(Math.cos(r)) * 127 + 64;
    d += Math.random() * 64;
    array[j] = d;
  }
}

function createColorRamp(array: number[]): three.Texture {
  const uintArray = new Uint8Array(array.length * 4);
  for (let j = 0; j < array.length; j++) {
    const color = array[j];
    uintArray[j * 4] = (color >> 16) & 255;
    uintArray[j * 4 + 1] = (color >> 8) & 255;
    uintArray[j * 4 + 2] = color & 255;
    uintArray[j * 4 + 3] = 255;
  }
  const t = new three.DataTexture(uintArray, array.length, 1, three.RGBAIntegerFormat, three.UnsignedByteType);
  t.internalFormat = "RGBA8UI";
  t.magFilter = three.NearestFilter;
  t.needsUpdate = true;
  return t;
}

/*
{
  let map;
  const img = new Image();
  img.src = "./assets/pix.png";
  // draw
  const canvas = document.createElement("canvas");
  canvas.width = 256;
  canvas.height = 256;

  const ctx = canvas.getContext("2d");
  if (ctx) {
    ctx.fillStyle = "cyan";
    ctx.fillRect(0, 0, 256, 256);
    ctx.fillStyle = "orange";
    for (let i = 0; i < 256; i += 32) {
      for (let j = 0; j < 256; j += 32) {
        ctx.fillRect(i, j, 16, 16);
      }
    }
  }
  map = new three.CanvasTexture(canvas);
  map.minFilter = three.NearestFilter;
  map.magFilter = three.NearestFilter;
}*/
