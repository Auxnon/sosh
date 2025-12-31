import * as THREE from "three";

export const player: THREE.Group = new THREE.Group();
export const cameraRef: { camera: THREE.PerspectiveCamera } = { camera: new THREE.PerspectiveCamera() };

// Face state management (8 faces in the spritesheet: 512 / 64 = 8)
export const faceState = { currentFace: 0 };
export const TOTAL_FACES = 8;

export function nextFace() {
    faceState.currentFace = (faceState.currentFace + 1) % TOTAL_FACES;
}

