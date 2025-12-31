import * as THREE from "three";

export const player: THREE.Group = new THREE.Group();
export const cameraRef: { camera: THREE.PerspectiveCamera } = { camera: new THREE.PerspectiveCamera() };

// Face state management (8 faces in the spritesheet: 512 / 64 = 8)
export const faceState = { currentFace: 0 };
export const TOTAL_FACES = 8;

// Animation state management
export const animationState = { 
    currentAnimation: 0,
    mixer: null as THREE.AnimationMixer | null,
    actions: [] as THREE.AnimationAction[],
    headBone: null as THREE.Bone | null
};
export const ANIMATIONS = ['idle', 'sit', 'carry'];

export function nextFace() {
    faceState.currentFace = (faceState.currentFace + 1) % TOTAL_FACES;
}

export function nextAnimation() {
    if (animationState.actions.length === 0) return;
    
    // Stop current animation
    if (animationState.actions[animationState.currentAnimation]) {
        animationState.actions[animationState.currentAnimation].stop();
    }
    
    // Move to next animation
    animationState.currentAnimation = (animationState.currentAnimation + 1) % animationState.actions.length;
    
    // Start new animation
    if (animationState.actions[animationState.currentAnimation]) {
        animationState.actions[animationState.currentAnimation].play();
    }
}

