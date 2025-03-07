import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/Addons.js";
import { Entity } from "./entity";

// const PI = Math.PI;
// const TAU = Math.PI * 2;

const pointer = new THREE.Vector2();
let cursor: THREE.Mesh;
// let player: THREE.Group;
const players: { [key: string]: Entity } = {};

let person: THREE.Group;

const root = new THREE.Group();
let playerId: string | undefined;
let player: Entity | undefined;

export function create(
  width: number = 400,
  height: number = 400,
): THREE.WebGLRenderer {
  // window.innerWidth / window.innerHeight,
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(75, width / height, 0.1, 1000);
  const renderer = new THREE.WebGLRenderer();
  camera.up.set(0, 0, 1);
  const controls = new OrbitControls(camera, renderer.domElement);
  // renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.setSize(width, height);
  renderer.setClearColor(0xc6eff7, 1);

  const raycaster = new THREE.Raycaster();

  // Set camera position
  // camera.rotateX(0.1 + PI / 2);
  // camera.position.y = -20;
  // camera.position.z = 6;
  camera.position.y = -20;
  camera.position.z = 6;

  const cube = (c: number) => {
    const g = new THREE.BoxGeometry();
    const m = new THREE.MeshBasicMaterial({ color: c });
    const cub = new THREE.Mesh(g, m);
    root.add(cub);
    // - md;
    return cub;
  };

  cube(0xff00ff);
  cube(0xff0000).position.set(1, 0, 0);
  cube(0x00ff00).position.set(0, 1, 0);
  cube(0x0000ff).position.set(0, 0, 1);
  const g = new THREE.PlaneGeometry(10, 10, 4, 4);
  const m = new THREE.MeshBasicMaterial({ color: 0xa4c93e });
  const plane = new THREE.Mesh(g, m);
  cursor = cube(0xff6600);
  root.add(plane);
  scene.add(root);

  const guy = new THREE.Group();

  // Body (cylinder)
  const bodyGeometry = new THREE.CylinderGeometry(0.2, 0.5, 2, 16);
  const bodyMaterial = new THREE.MeshBasicMaterial({ color: 0x3366cc });
  const body = new THREE.Mesh(bodyGeometry, bodyMaterial);
  body.position.y = 1;
  guy.add(body);

  // Head (sphere)
  const headGeometry = new THREE.SphereGeometry(0.5, 32, 32);
  const headMaterial = new THREE.MeshBasicMaterial({ color: 0xffccaa });
  const head = new THREE.Mesh(headGeometry, headMaterial);
  head.position.y = 2.5;
  guy.add(head);

  // Eyes
  const eyeGeometry = new THREE.SphereGeometry(0.2, 16, 16);
  const eyeMaterial = new THREE.MeshBasicMaterial({ color: 0xffffff });
  const pupilGeo = new THREE.PlaneGeometry(0.1, 0.2, 1, 1);
  const pupilMat = new THREE.MeshBasicMaterial({ color: 0x000000 });

  const eye = new THREE.Mesh(eyeGeometry, eyeMaterial);
  const pupil = new THREE.Mesh(pupilGeo, pupilMat);
  pupil.position.z = 0.2;
  eye.add(pupil);
  eye.position.set(-0.3, 2.5, 0.4);
  guy.add(eye);

  const rightEye = eye.clone();
  rightEye.position.set(0.3, 2.5, 0.4);
  guy.add(rightEye);

  // guy.rotateX(TAU / 4);
  guy.up = new THREE.Vector3(0, 0, 1);
  person = guy;

  const animate = () => {
    requestAnimationFrame(animate);
    // cube.rotation.x += 0.01;
    // cube.rotation.y += 0.01;
    // root.position.z+=1.01
    camera.updateProjectionMatrix();
    controls.update();
    raycaster.setFromCamera(pointer, camera);
    const intersects = raycaster.intersectObjects([plane]);
    if (intersects.length) {
      const c = intersects[0].point;
      processCursor(c.x, c.y, c.z);
    }
    renderer.render(scene, camera);
  };
  animate();
  return renderer;
}

function processCursor(x: number, y: number, z: number): void {
  const p = cursor.position;
  if (p.x !== x || p.y !== y || p.z !== z) {
    cursor.position.set(x, y, z);
    player?.mesh.lookAt(x, y, z);
  }
}

export function moveCursor(x: number, y: number) {
  // pointer.x = ( event.clientX / window.innerWidth ) * 2 - 1;
  // pointer.y = - ( event.clientY / window.innerHeight ) * 2 + 1;
  pointer.set(x * 2 - 1, -y * 2 + 1);
}

/** we assume moveCursor was already called by the event listener for a click */
export function click(): THREE.Vector3 {
  // player.position.copy(cursor.position);
  // player.position.x += 0.001;
  return cursor.position;
}

export function updateEntity(id: string, v: number[]) {
  const p = players[id];
  if (!p) return;

  p.mesh.position.set(v[0], v[1], v[2]);
}

export function joinEntity(id: string, v: number[]) {
  const p = person.clone();
  p.position.set(v[0], v[1], v[2]);
  const e = new Entity(id, p);
  players[id] = e;
  if (id == playerId) player = e;
  root.add(p);
}

export function setPlayer(id: string) {
  playerId = id;
  const p = players[id];
  if (p) player = p;
}
