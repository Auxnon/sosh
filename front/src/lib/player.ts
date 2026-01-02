import * as THREE from "three";
import { SkeletonUtils } from "three/examples/jsm/Addons.js";

export const TOTAL_FACES = 8;
export const ANIMATIONS = ["idle", "sit", "carry"];

export default class Player {
    object: THREE.Object3D
    face: THREE.Mesh;
    animationState: {
        currentAnimation: number;
        mixer: THREE.AnimationMixer | null;
        actions: THREE.AnimationAction[];
    };
    faceState: number = 0;
    waypoints: THREE.Vector3[] = [];
    constructor(
        private id: string,
        blueprint: THREE.Group<THREE.Object3DEventMap>,
        facePlane: THREE.Mesh,
        anims: THREE.AnimationClip[],
    ) {
        const obj = SkeletonUtils.clone(blueprint)
        const head = obj.getObjectByName("head");

        const mixer = new THREE.AnimationMixer(obj);



        let actions: THREE.AnimationAction[] = [];

        if (anims && anims.length > 0) {

            actions = anims.map((clip) => {
                const action = (
                    mixer as THREE.AnimationMixer
                ).clipAction(clip);
                action.setLoop(THREE.LoopRepeat, Infinity);
                return action
            });

            if (actions.length > 0) {
                actions[0].play();
            }
        }

        this.object = obj;

        this.face = facePlane.clone(true);
        head?.attach(this.face);
        // this.object.add(this.face)
        // this.object.rotateY(Math.PI / 2)
        this.animationState = {
            currentAnimation: 0,
            mixer,
            actions,
        };
    }
    getModel() {
        return this.object;
    }
    nextFace() {
        this.faceState = (this.faceState + 1) % TOTAL_FACES;
    }

    stopAnim() {
        if (this.animationState.actions[this.animationState.currentAnimation]) {
            this.animationState.actions[this.animationState.currentAnimation].stop();
        }
    }

    playAnim() {
        if (this.animationState.actions[this.animationState.currentAnimation]) {
            this.animationState.actions[this.animationState.currentAnimation].play();
        }
    }

    nextAnim() {
        if (this.animationState.actions.length === 0) return 0;
        this.stopAnim();

        this.animationState.currentAnimation =
            (this.animationState.currentAnimation + 1) % this.animationState.actions.length;


        this.playAnim();

        return this.animationState.currentAnimation
    }
    setAnim(id: number) {
        this.stopAnim()
        this.animationState.currentAnimation = id;
        this.playAnim();
    }
    getAnimationName(): string {
        return ANIMATIONS[this.animationState.currentAnimation]
    }
    setFace(id: number) {
        this.faceState = id;
        const mat = this.face.material as THREE.MeshBasicMaterial
        if (mat.map)
            mat.map.offset.x = this.faceState / TOTAL_FACES
    }
    getFace(): number {
        return this.faceState;
    }

    getPosition() {
        return this.object.position
    }

    clone(id: string, blueprint:
        THREE.Group<THREE.Object3DEventMap>, anims: THREE.AnimationClip[]) {
        const p = new Player(id, blueprint, this.face, anims)
        return p
    }

    addWaypoint(point: THREE.Vector3) {
        this.waypoints.push(point);
    }
    runAnim(rate: number) {
        return 
        this.animationState.mixer?.update(rate);
    }

    move(): boolean {
        const current = this.waypoints[0];
        if (current) {
            const speed = 0.1;
            const dx = current.x - this.object.position.x;
            const dy = current.z - this.object.position.z;
            const r = Math.sqrt(dx * dx + dy * dy);
            // this.object.rotation.order='ZXY'
            const ry = Math.atan2(dy, -dx) - Math.PI / 2

            // const euler = new THREE.Euler(0, ry, 0);
            //
            // const quaternion = new THREE.Quaternion();
            // quaternion.setFromEuler(euler);
            //
            // this.object.setRotationFromQuaternion(quaternion);
            // this.object.matrixAutoUpdate=true;
            // console.log(this.object.rotation)
            this.object.rotation.y=ry

            if (r < speed * 2) {
                if (r <= 0.1) return false
                // @ts-expect-error
                this.object.position.copy(this.waypoints.shift());
                return true;
            } else {
                this.object.position.x += (speed * dx) / r;
                this.object.position.z += (speed * dy) / r;
                // this.object.position.y+=0.1
                return true;
            }

        }
        return false
    }

}
