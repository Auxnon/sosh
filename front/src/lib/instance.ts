import * as three from "three";

export function create(element: HTMLCanvasElement) {
  const scene = new three.Scene();
  const camera = new three.PerspectiveCamera(75, element.clientWidth / element.clientHeight, 0.1, 1000);

  const renderer = new three.WebGLRenderer({ canvas: element });
  renderer.setSize(element.clientWidth, element.clientHeight);

  const geometry = new three.BoxGeometry();
  const material = new three.MeshBasicMaterial({ color: 0x00ff00 });
  const cube = new three.Mesh(geometry, material);
  scene.add(cube);

  camera.position.z = 5;

  function animate() {
    requestAnimationFrame(animate);
    cube.rotation.x += 0.01;
    cube.rotation.y += 0.01;
    renderer.render(scene, camera);
  }

  animate();
}
