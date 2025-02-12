import { Vector3 as V3, Object3D } from "three";

export class Entity {
  // @ts-expect-error yeah
  private id: string = "";
  target?: V3;
  // cache of next targets
  path: V3[] = [];
  defaultSpeed = 0.2;
  speed = this.defaultSpeed;

  constructor(
    id: string,
    public mesh: Object3D,
  ) {
    this.id = id;
  }

  animate(delta: number) {
    if (this.target) {
      const p = this.mesh.position.clone();
      const t = this.target;
      p.sub(t);
      const dist = p.length();
      const adjustedSpeed = this.speed * delta;
      if (dist < adjustedSpeed) {
        this.mesh.position.set(t.x, t.y, t.z);
        this.target = undefined;
      } else {
        this.mesh.position.add(p.normalize().multiplyScalar(adjustedSpeed));
      }
    }
  }

  move(v: V3, skip?: V3) {
    const compensate = skip?.distanceTo(this.mesh.position) || 0;
    if (compensate > this.speed * 2) {
      // we'll disregard anything less than 2 frames
      console.log("compensate for :" + compensate / this.speed);
    }
    this.target = v;
  }
}
