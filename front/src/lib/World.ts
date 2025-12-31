import * as THREE from "three";
import { socketService } from "./socket";

export const player: THREE.Group = new THREE.Group();
export const cameraRef: { camera: THREE.PerspectiveCamera } = { camera: new THREE.PerspectiveCamera() };

// Other players management
export const otherPlayers: Map<string, {
    group: THREE.Group;
    animationState: {
        currentAnimation: number;
        mixer: THREE.AnimationMixer | null;
        actions: THREE.AnimationAction[];
    };
    faceState: { currentFace: number };
}> = new Map();

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
    socketService.sendFace(faceState.currentFace);
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
    
    socketService.sendAnimation(animationState.currentAnimation);
}

export function sendPlayerPosition() {
    const pos = player.position;
    socketService.sendMove([pos.x, pos.y, pos.z]);
}

