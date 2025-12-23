import * as THREE from "three";
// export let count = $state(0);
//
// export function increment() {
//   count++;
// }

export const player: THREE.Group = new THREE.Group();
export const cameraRef: { camera: THREE.Camera } = { camera: new THREE.Camera() };

