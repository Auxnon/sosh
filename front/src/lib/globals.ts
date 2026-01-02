import * as THREE from "three";
import { socketService } from "./socket";
import Player from "./player";

export let player: {ref: Player} ={ ref: null!};
export const cameraRef: { camera: THREE.PerspectiveCamera } = {
  camera: new THREE.PerspectiveCamera(),
};

export const players: Map<
  string,Player
> = new Map();

export function nextFace() {
  player.ref.nextFace();
  socketService.sendFace(player.ref.getFace());
}

export function nextAnimation() {
  const anim = player.ref.nextAnim();
  socketService.sendAnimation(anim);
}

export function sendPlayerPosition() {
  const pos = player.ref.getPosition();
  socketService.sendMove([pos.x, pos.y, pos.z]);
}
