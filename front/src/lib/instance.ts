import * as three from "three";
import { OrbitControls } from "three/examples/jsm/Addons.js";
// import { OrbitControls } from "three/examples/jsm/controls/OrbitControls";

export function create(element: HTMLCanvasElement) {
  const scene = new three.Scene();
  const root = new three.Group();
  root.position.set(0, -5, 0);
  scene.add(root);
  const cam = new three.PerspectiveCamera(75, element.clientWidth / element.clientHeight, 0.1, 1000);

  const renderer = new three.WebGLRenderer({ canvas: element, alpha: false });
  renderer.setSize(element.clientWidth, element.clientHeight);
  renderer.setClearColor(0x999955, 1);

  const controls = new OrbitControls(cam, renderer.domElement);

  const geometry = new three.BoxGeometry();
  const material = new three.MeshBasicMaterial({ color: 0xff00ff });

  // const map = new three.TextureLoader().load("/assets/pix.png");
  // const material = new three.SpriteMaterial({ color: 0xffffff, map });
  const cube = new three.Mesh(geometry, material);
  root.add(cube);
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

  // const light = new three.DirectionalLight(0xffffff, 1);
  // light.intensity = 1;
  // light.position.set(0, 0, 10);
  // scene.add(light);

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
    for (let i = 0; i < points.length; i++) {
      const v2 = points[i].clone();
      v2.x += 1;
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
          .cross(new three.Vector3(0, 0, 1));
        // const dir = points[i]
        //   .clone()
        //   .sub(points[i - 1])
        //   .normalize();
        // A B
        // C D
        const a = c - 2;
        const b = d - 2;
        const ii = i * 6;
        // tri 1 ABC
        indices[ii] = a;
        indices[ii + 1] = b;
        indices[ii + 2] = d;
        // console.log(a, b, c);
        // tri 2 DCB
        indices[ii + 3] = d;
        indices[ii + 4] = c;
        indices[ii + 5] = a;

        norms[c] = new three.Vector3();
        norms[d] = perp;
        // console.log(d, c, b);
      }
    }
    norms[norms.length - 2] = norms[norms.length - 3];
    norms[norms.length - 1] = norms[norms.length - 2];

    const geometry = new three.BufferGeometry().setFromPoints(verts);
    geometry.setIndex(indices);

    const vs = verts.flatMap((v) => [v.x, v.y, v.z]);
    geometry.setAttribute("position", new three.Float32BufferAttribute(vs, 3));

    const ns = norms.flatMap((v) => [v.x, v.y, v.z]);
    geometry.setAttribute("normal", new three.Float32BufferAttribute(ns, 3));

    // const img = new Image();
    // img.src = "https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png";
    // const map = new three.TextureLoader().load(
    //   "https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png"
    // );
    // const material = new three.SpriteMaterial({ color: 0xff0000, side: three.DoubleSide, map });
    // const material = new three.PointsMaterial({ color: 0xff0000, size: 0.1 });
    const material = new three.ShaderMaterial({
      uniforms: {
        color: { value: new three.Color(0xff0000) },
      },
      vertexShader: `
        uniform vec3 color;
        varying vec3 vColor;
        varying vec4 vPos;
        // attribute vec3 normal;
        varying vec3 vNormal;


        void main() {
            vColor = color;
            vNormal = normal;
            vPos = projectionMatrix * modelViewMatrix * vec4(position+normal*3., 1.0);
             
            gl_Position = vPos;
        }
      `,
      fragmentShader: `
        varying vec3 vColor;
        varying vec4 vPos;
        varying vec3 vNormal;
        void main() {
          vec2 vCoords = vPos.xy;
          vCoords /= vPos.w;
          vCoords = vCoords * 0.5 + 0.5;
          vec2 uv = fract( vCoords * 10.0 );

          // gl_FragColor = vec4(vNormal, 1.0);
          gl_FragColor = vec4(vColor, 1.0);
          // gl_FragColor = vec4(uv, 0.0, 1.0);
        }
      `,
      side: three.DoubleSide,
    });

    // Create the final object to add to the scene
    const mesh = new three.Mesh(geometry, material);

    const simpleGeometry = new three.BufferGeometry().setFromPoints(points);
    const simpleMaterial = new three.LineBasicMaterial({ color: 0xff0000, linewidth: 20 });
    const simple = new three.Line(simpleGeometry, simpleMaterial);
    root.add(simple);
    root.add(mesh);
  }

  function animate() {
    requestAnimationFrame(animate);
    // root.rotation.x += 0.01;
    // root.rotation.y += 0.01;
    controls.update();
    renderer.render(scene, cam);
  }

  animate();
}
