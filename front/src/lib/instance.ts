import * as three from "three";

export function create(element: HTMLCanvasElement) {
  const scene = new three.Scene();
  const root = new three.Group();
  scene.add(root);
  const cam = new three.PerspectiveCamera(75, element.clientWidth / element.clientHeight, 0.1, 1000);

  const renderer = new three.WebGLRenderer({ canvas: element, alpha: false });
  renderer.setSize(element.clientWidth, element.clientHeight);

  const geometry = new three.BoxGeometry();
  const material = new three.MeshBasicMaterial({ color: 0x00ff00 });
  const cube = new three.Mesh(geometry, material);
  root.add(cube);
  const gridHelper1 = new three.GridHelper(10, 10);
  const gridHelper2 = gridHelper1.clone();
  const gridHelper3 = gridHelper1.clone();
  gridHelper1.position.y = -5;
  gridHelper2.position.x = 5;
  gridHelper2.rotation.z = Math.PI / 2;

  gridHelper3.rotation.x = Math.PI / 2;
  gridHelper3.position.z = 5;

  root.add(gridHelper1);
  root.add(gridHelper2);
  root.add(gridHelper3);

  cam.position.z = 30;

  {
    // curve
    const curve = new three.CatmullRomCurve3([
      new three.Vector3(-10, 0, 10),
      new three.Vector3(-5, 5, 5),
      new three.Vector3(0, 0, 0),
      new three.Vector3(5, -5, 5),
      new three.Vector3(10, 0, 10),
    ]);

    const points = curve.getPoints(50);
    const geometry = new three.BufferGeometry().setFromPoints(points);

    const material = new three.LineBasicMaterial({ color: 0xff0000 });

    // Create the final object to add to the scene
    const curveObject = new three.Line(geometry, material);
    root.add(curveObject);
  }

  function animate() {
    requestAnimationFrame(animate);
    // root.rotation.x += 0.01;
    root.rotation.y += 0.01;
    renderer.render(scene, cam);
  }

  animate();
}
