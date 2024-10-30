import { Vector3, Box3 } from "three";
import * as three from "three";
import { OrbitControls } from "three/examples/jsm/Addons.js";

interface Curve {
  verts: Float32Array;
  indices: number[];
  norms: three.Vector3[];
  uvs: three.Vector2[];
  bounds: Box3[];
}

const DEBUG = true;
const MAX_DATA = 16384;
const RELATIVE_DATA_MODE = true;

const THRESHOLD = 4;
let cam: three.Camera;
let scene: three.Scene;
let root: three.Group;
const BoundPointThreshold = 5;
/** boxes of ribbon need to be slightly larger by scale, may need to be rebuilt on */
let boxes: Box3[];
/** same as boxes with a scale hypotenuse applied to compensate for scaled ribbon, rebuilt on zoom*/
let scaledBoxes: Box3[];
/** bounding box assocaitd points along same indicies. For instance, box at instance 1 would have it's associated ribbon points also on index 1*/
let boxPointSets: { start: number; end: number }[];
let testTri: three.Mesh;
let triGeo: three.BufferGeometry;
let triVerts: Float32Array;

/** DEBUG ONLY bounding box helpers */
let boxMeshRef: three.Box3Helper[] = [];
let arrow: three.ArrowHelper;

const WARP = false;
let BILLBOARD = false;
const NAME = "RibbonGraphic";

class BillboardedRibbon extends three.Mesh {
  constructor(
    geom: three.BufferGeometry,
    mat: three.Material,
    public points: Vector3[],
  ) {
    super(geom, mat);
  }

  /** @inheritDoc */
  raycast(raycaster: three.Raycaster, intersects: three.Intersection[]): void {
    let point;
    let max = THRESHOLD;
    let index;
    let array: number[] = [];
    let prev_dist;
    let prev_v;
    let prev;
    let next;
    // let nextd;
    for (let i = 0; i < this.points.length; i++) {
      const v = this.points[i];

      const d = raycaster.ray.distanceToPoint(v);
      if (prev_v) {
        // const segd = raycaster.ray.distanceSqToSegment(v, prev_v);
        const mat = cam.matrixWorldInverse;
        const e = mat.elements;
        // vec3 cameraRight=vec3(viewMatrix[0].x,viewMatrix[1].x,viewMatrix[2].x);
        const camR = new Vector3(e[0], e[4], e[8]).multiplyScalar(4);
        const perp = prev_v.clone().add(camR);
        const perp2 = v.clone().add(camR);
        const dummy = new Vector3();
        const tri = raycaster.ray.intersectTriangle(
          prev_v,
          v,
          perp,
          false,
          dummy,
        );
        const tri2 = raycaster.ray.intersectTriangle(
          v,
          perp2,
          perp,
          false,
          dummy,
        );
        if (DEBUG && (tri || tri2)) {
          if (tri) {
            triVerts.set([
              ...prev_v.toArray(),
              ...v.toArray(),
              ...perp.toArray(),
            ]);
          } else if (tri2) {
            triVerts.set([
              ...v.toArray(),
              ...perp2.toArray(),
              ...perp.toArray(),
            ]);
          }
          testTri.geometry.attributes.position.needsUpdate = true;
        }
      }
      if (d < max) {
        prev = prev_dist;
        max = d;
        point = v;
        index = i;
        // next = undefined;
      } else if (i - 1 == index) {
        next = d;
      }
      prev_dist = d;
      prev_v = v;
    }
    console.log(array);
    if (!point) {
      return;
    }

    if (prev !== undefined || next !== undefined) {
      prev ??= 999;
      next ??= 999;
      const offset = prev < next ? -(max / prev) : max / next;
      // @ts-ignore will always be defined if we hit here
      // index-=offset;
    }

    console.log(index);
    const vec = new three.Vector3(0, 0, 0);
    const interVec = raycaster.ray.closestPointToPoint(point, vec);
    if (!arrow) {
      arrow = new three.ArrowHelper(new three.Vector3(), point, 30, 0xff0000);
      arrow.setLength(3.5, 0.5, 0.33);
      scene.add(arrow);
    }
    arrow.position.set(point.x, point.y, point.z);
    arrow.setDirection(interVec.sub(point).normalize());
    const intersection: three.Intersection = {
      distance: max,
      point,
      index,
      face: null,
      faceIndex: undefined,
      object: this,
    };

    // intersection.faceIndex = Math.floor( j / 3 ); // triangle number in indexed buffer semantics
    // intersection.face.materialIndex = group.materialIndex;
    intersects.push(intersection);
  }
}



class RibbonGraphic extends Abstract {
  public readonly CustomTooltip = true;
  isSnap = true;
  scale = 4;
  divisor;
  geometry: three.BufferGeometry;
  texture: three.DataTexture;
  /** reference to the buffer used internally by the value data texture, set this ref to update values */
  valueArray: Uint8ClampedArray;
  /** reusable data representing colors to apply at certain percentages*/
  colorRampData: Uint8Array;
  dataHeight = MAX_DATA;
  ribbonMaterial: three.ShaderMaterial;
  WARP = false;

  constructor(service: BoreHoleService) {
    super();
    this.setName(NAME);
    this.ISelectable = NAME;
    const root: three.Object3D = this.getThreeNode();
    root.userData[PickResult.OWNER_KEY] = this;

    const { texture, array } = createTestTexture();
    this.valueArray = array;
    this.divisor = 1 / array.length;

    let p: three.Vector3[];
    try {
      p = service.getBaseWellStringCurve3().getPoints();
    } catch (e) {
      p = [
        new three.Vector3(0, 0, 0),
        new three.Vector3(0, 10, 0),
        new three.Vector3(0, 20, 0),
      ];
    }

    {
      const points = new Float32Array(p.flatMap((v) => [v.x, v.y, v.z]));

      const { verts, indices, norms, uvs } = this.buildCurve(points);

      const geometry = new three.BufferGeometry();
      geometry.setIndex(indices);

      geometry.setAttribute(
        "position",
        new three.Float32BufferAttribute(verts, 3),
      );

      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      let iii = 0;
      try {
        const ns = norms.flatMap((v) => {
          iii++;
          return [v.x, v.y, v.z];
        });
        geometry.setAttribute(
          "normal",
          new three.Float32BufferAttribute(ns, 3),
        );
      } catch (e) {
        // eslint-disable-next-line no-debugger
        debugger;
      }

      const us = uvs.flatMap((v) => [v.x, v.y]);
      geometry.setAttribute("uv", new three.Float32BufferAttribute(us, 2));

      const colors = [0x7c00db, 0x0644e9, 0x16ac25, 0xfefa01, 0xf5bd02];
      const percents = [0, 0.2, 0.4, 0.6, 0.8];
      const ramp = this.createColorRampTexture(colors, percents, 250);

      this.ribbonMaterial = new three.ShaderMaterial({
        uniforms: {
          color: { value: new three.Color(0x00ff00) },
          tex: {
            value: texture,
          },
          ramp: {
            value: ramp,
          },
          highlight: { value: 0.5 },
          divisor: { value: this.divisor / 2 },
          dataHeight: { value: this.dataHeight },
          billboard: { value: true },
          scale: { value: 1 },
        },
        vertexShader: `
uniform vec3 color;
varying vec3 vColor;
varying vec4 vPos;
varying vec4 vNormal;
varying vec2 vUv;
uniform bool billboard;
uniform float scale;

void main() {
    vColor = color;
    vUv = uv;
    if(billboard) {
        vec3 cameraRight=vec3(-viewMatrix[0].x,viewMatrix[1].x,viewMatrix[2].x);
        // vec3 cameraUp=vec3(viewMatrix[0].y,viewMatrix[1].y,viewMatrix[2].y);
        // vec3 vPosition=(cameraRight*position.x)+(cameraUp*position.y);
        vPos = projectionMatrix * modelViewMatrix * vec4(position + normal*cameraRight*scale, 1.0);
    } else {
        vPos = projectionMatrix * modelViewMatrix * vec4(position + vec3(1.,0.,0.) * scale, 1.0);
    }

    vNormal = vec4(normal, 1.0);
    gl_Position = vPos;
}

      `,
        fragmentShader: `
        varying vec3 vColor;
        varying vec4 vPos;
        varying vec4 vNormal;
        varying vec2 vUv;
        uniform mediump usampler2D tex;
        uniform mediump usampler2D ramp;
        uniform float highlight;
        uniform float divisor;
        uniform float dataHeight;

        void main() {
          // if between highlight minus 0.1 and highlight plus 0.1
          vec2 uv2 = vec2(vUv.x*dataHeight,vUv.y);
          uint p = texture(tex, uv2).r;
          float f = float(p) / 255.0;
          uvec4 c = texture(ramp, vec2(f, 0.5));
          if (f < vUv.y) {
            discard;
          } else {
            vec4 final = vec4(float(c.r) / 255.0, float(c.g) / 255.0, float(c.b) / 255.0, 1.0);
            float v1= highlight - 7.*divisor;
            float v2= highlight -divisor;
            float v3= highlight +divisor;
            float v4= highlight + 7.*divisor;
            if (vUv.x > v1 && vUv.x < v2 || vUv.x > v3 && vUv.x < v4) {
             final /= 4.0;
            }
            gl_FragColor  = final;
          }

        }

      `,
        side: three.DoubleSide,
      });

      this.geometry = geometry;
      this.texture = texture;
      // Create the final object to add to the scene
      const mesh = new BillboardedRibbon(geometry, this.ribbonMaterial);
      mesh.name = NAME;
      root.add(mesh);
      this.setBoundDirty(true);
    }
  }

  rebuild(
    points: Float32Array,
    values: Float32Array,
    min: number,
    max: number,
  ): void {
    const { verts, indices, norms, uvs } = this.buildCurve(points);
    this.remakeTexture(values, min, max);
    this.geometry.setAttribute(
      "position",
      new three.Float32BufferAttribute(verts, 3),
    );
    this.geometry.setIndex(indices);
    this.geometry.setAttribute(
      "normal",
      new three.Float32BufferAttribute(
        norms.flatMap((v) => [v.x, v.y, v.z]),
        3,
      ),
    );
    this.geometry.setAttribute(
      "uv",
      new three.Float32BufferAttribute(
        uvs.flatMap((v) => [v.x, v.y]),
        2,
      ),
    );
    this.setBoundDirty(true);
  }

  remakeTexture(values: Float32Array, min: number, max: number): void {
    const uintSize = values.length;
    // var oldBuffer = new ArrayBuffer(20);

    // var newBuffer = new ArrayBuffer(40);
    // new Uint8Array(newBuffer).set(oldBuffer);
    // this.valueBuffer.set()

    // const img = this.texture.image;
    const data = new Uint8ClampedArray(uintSize);
    if (RELATIVE_DATA_MODE) {
      // relative min max to current dataset
      let rmin = Infinity;
      let rmax = -Infinity;
      for (let j = 0; j < uintSize; j++) {
        const v = values[j];
        if (v < rmin) rmin = v;
        if (v > rmax) rmax = v;
      }
      min = rmin;
      max = rmax;
    }
    for (let j = 0; j < uintSize; j++) {
      const v = values[j];
      const n = Math.min(Math.max(v, min), max) / max;
      data[j] = Math.floor(n * 255);
    }

    // this.valueBuffer.subarray(0, data.length);
    // this.valueBuffer.buffer.
    this.valueArray.set(data, 0);
    this.dataHeight = uintSize / MAX_DATA;

    this.ribbonMaterial.uniforms.dataHeight.value = this.dataHeight;
    // this.texture.
    // this.texture.image = { data, width: uintSize, height: 1 };
    // const texture = new three.DataTexture(uintArray, uintSize, 1, three.RedIntegerFormat, three.UnsignedByteType);
    // texture.internalFormat = 'R8UI';
    // TODO is this even necessary still since the uniform is all that changes?
    this.texture.needsUpdate = true;
  }

  buildCurve(points: Float32Array): Curve {
    const size = points.length * 2;
    const verts: Float32Array = new Float32Array(size);
    const indices = new Array(size - 6);
    const norms: three.Vector3[] = new Array(size / 3);
    const uvs = new Array(size / 3);

    /** Keeps track of current point count before resetting on a new bound box*/
    let pointCount = 0;
    let min = new Vector3();
    let max = new Vector3();
    min.set(Infinity, Infinity, Infinity);
    max.set(-Infinity, -Infinity, -Infinity);
    let bounds: Box3[] = [];

    const resetBound = (x?: number, y?: number, z?: number) => {
      const box = new Box3(min.clone(), max.clone());
      bounds.push(box);
      if (x && y && z) {
        min.set(x, y, z);
        max.set(x, y, z);
      }
    };
    // const hverts: Float32Array = new Float32Array(size * 2);
    // const hinds = new Array(size * 2 - 12);

    uvs[0] = new three.Vector2(0, 0);
    uvs[1] = new three.Vector2(0, 1);
    for (let i = 0; i < points.length; i += 3) {
      const vx = points[i];
      const vy = points[i + 1];
      const vz = points[i + 2];

      const vi = i / 3;

      const vc = i * 2;
      const vd = i * 2 + 3;

      const c = vi * 2;
      const d = vi * 2 + 1;

      if (i > 0) {
        const ii = i * 6;
        // A B
        // C D
        const a = c - 2;
        const b = d - 2;
        // const ii = i * 6;
        // tri 1 ABC
        indices[ii] = a;
        indices[ii + 1] = b;
        indices[ii + 2] = d;
        // tri 2 DCB  // dca
        indices[ii + 3] = d;
        indices[ii + 4] = c;
        indices[ii + 5] = a;

        norms[c] = new three.Vector3();
        // norms[d] = perp;
        norms[d] = new three.Vector3(1, 1, 1);
        const u = i / points.length;
        uvs[c] = new three.Vector2(u, 0);
        uvs[d] = new three.Vector2(u, 1);
      }

      verts[vd] = verts[vc] = points[i];
      verts[vd + 1] = verts[vc + 1] = points[i + 1];
      verts[vd + 2] = verts[vc + 2] = points[i + 2];

      /// bounding box iteration
      if (vx > max.x) max.x = vx;
      if (vx < min.x) min.x = vx;
      if (vy > max.y) max.y = vy;
      if (vy < min.y) min.y = vy;
      if (vz > max.z) max.z = vz;
      if (vz < min.z) min.z = vz;

      pointCount++;
      if (pointCount >= BoundPointThreshold) {
        pointCount = 0;
        resetBound(vx, vy, vz);
      }

      // const hi = vi * 4;
      // hverts[hi] = verts[vc];
      // hverts[hi + 1] = verts[vc + 1];
      // hverts[hi + 2] = verts[vc + 2];
      //
      // hverts[hi] = verts[vc];
      // hverts[hi + 1] = verts[vc + 1];
      // hverts[hi + 2] = verts[vc + 2];
    }
    resetBound();
    boxes = bounds;
    scaledBoxes = boxes.map((b) => b.clone());

    if (DEBUG) {
      boxMeshRef.forEach((b) => root.remove(b));
      boxMeshRef = [];
      scaledBoxes.forEach((b) => {
        const helper = new three.Box3Helper(b, 0xff00ff);
        boxMeshRef.push(helper);
        root.add(helper);
      });
    }
    norms[0] = norms[2];
    norms[1] = norms[3];
    norms[norms.length - 2] = norms[norms.length - 3];
    norms[norms.length - 1] = norms[norms.length - 2];
    uvs[uvs.length - 2] = new three.Vector2(1, 0);
    uvs[uvs.length - 1] = new three.Vector2(1, 1);
    const ii = indices.length - 3;
    const a = (2 * (points.length - 1)) / 3;
    indices[ii] = a - 1;
    indices[ii + 1] = a;
    indices[ii + 2] = a - 2;
    return { verts, indices, norms, uvs, bounds };
  }

  createColorRampTexture(
    colors: number[],
    percents: number[],
    resolution: number,
  ): three.Texture {
    const uintArray = createColorRamp(colors, percents, resolution);
    this.colorRampData = uintArray;
    const t = new three.DataTexture(
      uintArray,
      resolution,
      1,
      three.RGBAIntegerFormat,
      three.UnsignedByteType,
    );
    t.internalFormat = "RGBA8UI";
    t.magFilter = three.NearestFilter;
    t.needsUpdate = true;
    return t;
  }

  remakeColorRampTexture(
    colors: number[],
    percents: number[],
    resolution: number,
  ): void {
    const uintArray = createColorRamp(colors, percents, resolution);
    this.colorRampData.set(uintArray);
  }

  createDebug(parent: three.Object3D) {
    const triMat = new three.MeshBasicMaterial({
      color: 0xff00ff,
      side: three.DoubleSide,
    });
    // const vec = (x: number, y: number, z: number) => new Vector3(x, y, z);
    triGeo = new three.BufferGeometry();
    triVerts = new Float32Array([0, 0, 0, 12, 0, 0, 12, 12, 0]);
    triGeo.setAttribute("position", new three.BufferAttribute(triVerts, 3));
    testTri = new three.Mesh(triGeo, triMat);
    parent.add(testTri);
  }

  createTestTexture(): {
    texture: three.DataTexture;
    array: Uint8ClampedArray;
  } {
    const uintSize = 2000;
    // by using an arraybuffer instead of directly creating the TypeArray we can specify the memory address is resizable
    const uintArray = new Uint8ClampedArray(uintSize);

    dataHeight = uintSize / MAX_DATA;
    alternatingArray(uintArray);
    const texture = new three.DataTexture(
      uintArray,
      uintSize,
      1,
      three.RedIntegerFormat,
      three.UnsignedByteType,
    );
    // texture.internalFormat = "RGBA8UI";
    texture.internalFormat = "R8UI";
    // texture.magFilter = three.NearestFilter;
    texture.needsUpdate = true;

    return { texture, array: uintArray };
  }

  setScale(scale: number): void {
    this.scale = scale;
    this.ribbonMaterial.uniforms.scale.value = this.scale;
  }

  rescaleBoxes() {
    const n = scale;
    for (let i = 0; i < boxes.length; i++) {
      const b = boxes[i];
      const sb = scaledBoxes[i];
      sb.min.set(b.min.x - n, b.min.y, b.min.z - n);
      sb.max.set(b.max.x + n, b.max.y, b.max.z + n);
    }
  }

  /** @inheritdoc */
  drawBegin(_view: View): void {}

  /** @inheritdoc */
  drawEnd(_view: View): void {}

  // /** @inheritdoc */
  // buildToolTip(picks: IPickResult[]): string {
  //   const details = picks[0].getDetail().getDetails();
  //   const value: number = details.get("VALUE");
  //
  //   return `<div>${value}</div>`;
  // }
  //
  // computePickDetail(result: IPickResult): IPickDetail {
  //   const detail = new PickDetail();
  //   detail.addDetail("NAME", NAME);
  //   // TODO how will this work with a remote viewer?
  //   if (result.IPickResult === "Local Pick Result") {
  //     const inter = (result as PickResult).getIntersection();
  //     if (inter) {
  //       let value = 0;
  //       const divisor = this.divisor;
  //       if (inter.uv) {
  //         let index;
  //         if (this.isSnap) {
  //           index =
  //             -divisor / 2 +
  //             Math.floor((inter.uv.x + divisor) * this.valueArray.length) /
  //               this.valueArray.length;
  //         } else {
  //           index = inter.uv.x;
  //         }
  //
  //         value = this.valueArray[Math.floor(index * this.valueArray.length)];
  //         detail.addDetail("VALUE", value);
  //         this.ribbonMaterial.uniforms.highlight.value = index;
  //       }
  //     }
  //   } else {
  //     throw new Error("Mohawk does not support remote viewer at this time");
  //   }
  //
  //    return detail;
  // }
}

export function create(
  element: HTMLCanvasElement,
  pointSet: (point: Vector3) => void,
): void {
  console.log("create");

  scene = new three.Scene();
  root = new three.Group();
  root.position.set(0, 0, 0);
  scene.add(root);
  cam = new three.PerspectiveCamera(
    75,
    element.clientWidth / element.clientHeight,
    0.1,
    1000,
  );

  const renderer = new three.WebGLRenderer({ canvas: element, alpha: false });
  renderer.setSize(element.clientWidth, element.clientHeight);
  renderer.setClearColor(0xc6eff7, 1);

  const controls = new OrbitControls(cam, renderer.domElement);

  const raycaster = new three.Raycaster();
  const pointer = new three.Vector2();
  let ribbonMesh: BillboardedRibbon;
  let ribbonMaterial: three.ShaderMaterial;

  const cube = (c: number) => {
    const geometry = new three.BoxGeometry();
    const material = new three.MeshBasicMaterial({ color: c });
    const cub = new three.Mesh(geometry, material);
    root.add(cub);
    return cub;
  };
  cube(0xff00ff);
  cube(0xff0000).position.set(1, 0, 0);
  cube(0x00ff00).position.set(0, 1, 0);
  cube(0x0000ff).position.set(0, 0, 1);
  const mover = cube(0x00ffff);
  mover.scale.set(0.01, 0.01, 0.01);

  const gridHelper1 = new three.GridHelper(10, 10);
  const gridHelper2 = gridHelper1.clone();
  const gridHelper3 = gridHelper1.clone();

  gridHelper2.position.y = 5;
  gridHelper2.position.x = 5;
  gridHelper2.rotation.z = Math.PI / 2;

  gridHelper3.rotation.x = Math.PI / 2;
  gridHelper3.position.y = 5;
  gridHelper3.position.z = 5;

  root.add(gridHelper1);
  root.add(gridHelper2);
  root.add(gridHelper3);

  cam.position.z = 20;

  const curve = new three.CatmullRomCurve3([
    new three.Vector3(0, 20, -10),
    new three.Vector3(0, 10, 0),
    new three.Vector3(0.4, 8, 0.1),
    new three.Vector3(1.2, 6, -3),
    new three.Vector3(0.1, 4, -4),
    // new three.Vector3(-6, 2, 7),
    // new three.Vector3(-0.6, 0, -12),
  ]);
  const points = curve.getPoints(40);
  const p = new Float32Array(points.length * 3);
  for (let i = 0; i < points.length; i++) {
    p[i * 3] = points[i].x;
    p[i * 3 + 1] = points[i].y;
    p[i * 3 + 2] = points[i].z;
  }

  /// BLUE

  const { texture, array } = createTestTexture();

  this.valueArray = array;
  const divisor = 1 / array.length;
  {
    const { verts, indices, norms, uvs } = buildCurve(p);

    const geometry = new three.BufferGeometry();

    geometry.setAttribute(
      "position",
      new three.Float32BufferAttribute(verts, 3),
    );

    // geometry.setAttribute("index", new three.Uint16BufferAttribute(indices, 1));
    geometry.setIndex(indices);

    const ns = norms.flatMap((v) => [v.x, v.y, v.z]);
    geometry.setAttribute("normal", new three.Float32BufferAttribute(ns, 3));

    const us = uvs.flatMap((v) => [v.x, v.y]);
    geometry.setAttribute("uv", new three.Float32BufferAttribute(us, 2));

    const colors = [0x7c00db, 0x0644e9, 0x16ac25, 0xfefa01, 0xf5bd02];
    const ramp = createColorRamp(colors);

    ribbonMaterial = new three.ShaderMaterial({
      uniforms: {
        color: { value: new three.Color(0x00ff00) },
        tex: {
          value: texture,
        },
        ramp: {
          value: ramp,
        },
        highlight: { value: 0.5 },
        divisor: { value: divisor / 2 },
        dataHeight: { value: dataHeight },
        billboard: { value: true },
        scale: { value: scale },
      },
      vertexShader: `
uniform vec3 color;
varying vec3 vColor;
varying vec4 vPos;
varying vec4 vNormal;
varying vec2 vUv;
uniform bool billboard;
uniform float scale;

void main() {
    vColor = color;
    vUv = uv;
    if(billboard) {
        vec3 cameraRight=vec3(viewMatrix[0].x,viewMatrix[1].x,viewMatrix[2].x);
        // vec3 cameraUp=vec3(viewMatrix[0].y,viewMatrix[1].y,viewMatrix[2].y);
        // vec3 vPosition=(cameraRight*position.x)+(cameraUp*position.y);
        vPos = projectionMatrix * modelViewMatrix * vec4(position + normal*cameraRight*scale, 1.0);
    } else {
        vPos = projectionMatrix * modelViewMatrix * vec4(position + vec3(1.,0.,0.) * scale, 1.0);
    }

    vNormal = vec4(normal, 1.0);
    gl_Position = vPos;
}
      `,
      fragmentShader: `
        varying vec3 vColor;
        varying vec4 vPos;
        varying vec4 vNormal;
        varying vec2 vUv;
        uniform mediump usampler2D tex;
        uniform mediump usampler2D ramp;
        uniform float highlight;
        uniform float divisor;
        uniform float dataHeight;

        void main() {
          // if between highlight minus 0.1 and highlight plus 0.1
          vec2 uv2 = vec2(vUv.x*dataHeight,vUv.y);
          uint p = texture(tex, uv2).r;
          float f = float(p) / 255.0;
          uvec4 c = texture(ramp, vec2(f, 0.5));
          if (f < vUv.y) {
            discard;
          } else {
            vec4 final = vec4(float(c.r) / 255.0, float(c.g) / 255.0, float(c.b) / 255.0, 1.0);
            float v1= highlight - 7.*divisor;
            float v2= highlight -divisor;
            float v3= highlight +divisor;
            float v4= highlight + 7.*divisor;
            if (vUv.x > v1 && vUv.x < v2 || vUv.x > v3 && vUv.x < v4) {
             final /= 4.0;
            }
            gl_FragColor  = final;
          }

        }
      `,
      side: three.DoubleSide,
    });

    // Create the final object to add to the scene
    ribbonMesh = new BillboardedRibbon(geometry, ribbonMaterial, points);
    // YELLOW

    const simpleGeometry = new three.BufferGeometry().setFromPoints(points);
    const simpleMaterial = new three.LineBasicMaterial({
      color: 0xff0000,
      linewidth: 1,
    });
    const simple = new three.Line(simpleGeometry, simpleMaterial);
    root.add(simple);
    root.add(ribbonMesh);
  }

  function alternatingArray(array: Uint8ClampedArray): void {
    for (let j = 0; j < array.length; j++) {
      array[j] = (j % 2) * 200 + 50;
    }
  }

  function animate() {
    requestAnimationFrame(animate);

    controls.update();

    raycaster.setFromCamera(pointer, cam);
    const intersects = raycaster.intersectObjects([ribbonMesh], true);
    if (intersects.length > 0) {
      const inter = intersects[0];

      const p = inter.point;
      let value = 0;
      // if (inter.uv) {
      // let index;
      // if (SNAP) {
      //   index =
      //     -divisor / 2 +
      //     Math.floor((inter.uv.x + divisor) * array.length) / array.length;
      // } else {
      //   index = inter.uv.x;
      // }
      const index = (inter.index || 0) / ribbonMesh.points.length;

      value = array[Math.floor(index * array.length)];

      ribbonMaterial.uniforms.highlight.value = index;
      // }
      pointSet(new Vector3(inter.uv?.x || 0, inter.uv?.y || 0, value));
      mover.position.x = p.x;
      mover.position.y = p.y + 5;
      mover.position.z = p.z;
      // mover.position.y += 0.02;
      // intersects[0].point
    }
    renderer.render(scene, cam);
  }

  window.addEventListener("pointermove", (e) => {
    pointer.x = (e.clientX / window.innerWidth) * 2 - 1;
    pointer.y = -(e.clientY / window.innerHeight) * 2 + 1;
  });
  window.addEventListener("keydown", (e) => {
    if (e.key === " ") {
      WARP = !WARP;
    } else if (e.key === "b") {
      // BILLBOARD = !BILLBOARD;
      // ribbonMaterial.uniforms.billboard.value = BILLBOARD;
      // rescaleBoxes();
    } else if (e.key === "s") {
      SNAP = !SNAP;
    }
  });

  animate();
}

function createTexture(): { texture: three.DataTexture; array: Uint8Array } {
  const uintSize = 1024;
  const uintArray = new Uint8Array(uintSize);
  warpArray(uintArray);
  const texture = new three.DataTexture(
    uintArray,
    uintSize,
    1,
    three.RedIntegerFormat,
    three.UnsignedByteType,
  );
  // texture.internalFormat = "RGBA8UI";
  texture.internalFormat = "R8UI";
  // texture.magFilter = three.NearestFilter;
  texture.needsUpdate = true;

  return { texture, array: uintArray };
}

function warpArray(array: Uint8Array): void {
  let r = 0;
  for (let j = 0; j < array.length; j++) {
    r += Math.random() * 0.1;
    let d = Math.abs(Math.cos(r)) * 127 + 64;
    d += Math.random() * 64;
    array[j] = d;
  }
}

function createColorRamp(
  colors: number[],
  percents: number[],
  resolution: number,
): Uint8Array {
  const uintArray = new Uint8Array(resolution * 4);
  if (colors.length !== percents.length) {
    throw "Cannot create a color ramp when color count doesn't match percentages";
  }
  let i = 0;
  for (let j = 0; j < colors.length; j++) {
    const perc = j / resolution;
    const p = percents[i];
    if (perc >= p) {
      i += 1;
      i = Math.min(i, colors.length - 1); // cap to last value
    }
    const color = colors[i];
    uintArray[j * 4] = (color >> 16) & 255;
    uintArray[j * 4 + 1] = (color >> 8) & 255;
    uintArray[j * 4 + 2] = color & 255;
    uintArray[j * 4 + 3] = 255;
  }
  return uintArray;
}



class Abstract {
  setName(_s: string): void {}
  setBoundDirty(_b: boolean): void {}
  ISelectable: string = "";
}

class View {}
/*
{
  let map;
  const img = new Image();
  img.src = "./assets/pix.png";
  // draw
  const canvas = document.createElement("canvas");
  canvas.width = 256;
  canvas.height = 256;

  const ctx = canvas.getContext("2d");
  if (ctx) {
    ctx.fillStyle = "cyan";
    ctx.fillRect(0, 0, 256, 256);
    ctx.fillStyle = "orange";
    for (let i = 0; i < 256; i += 32) {
      for (let j = 0; j < 256; j += 32) {
        ctx.fillRect(i, j, 16, 16);
      }
    }
  }
  map = new three.CanvasTexture(canvas);
  map.minFilter = three.NearestFilter;
  map.magFilter = three.NearestFilter;
}*/
