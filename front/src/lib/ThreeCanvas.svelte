<script lang="ts">
    import { onMount, onDestroy } from "svelte";
    import * as THREE from "three";
    import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
    import { player, cameraRef, faceState, TOTAL_FACES } from "./World";
    import facesUrl from "../../assets/faces.png";

    let canvasElement: HTMLCanvasElement;
    let scene: THREE.Scene;
    let renderer: THREE.WebGLRenderer;
    let controls: OrbitControls;
    let animationId: number;
    let raycaster: THREE.Raycaster;
    let mouse: THREE.Vector2;
    let clickStartTime: number;
    let hasMoved = false;
    let isDragging = false;
    let plane: THREE.Mesh;
    let facePlane: THREE.Mesh;
    let faceMaterial: THREE.MeshBasicMaterial;
    const PI = Math.PI;

    let movePoints: THREE.Vector3[] = [];

    onMount(() => {
        if (!canvasElement) return;

        // Scene setup
        scene = new THREE.Scene();
        scene.background = new THREE.Color(0x87ceeb);

        // Camera setup
        cameraRef.camera = new THREE.PerspectiveCamera(
            75,
            window.innerWidth / window.innerHeight,
            0.1,
            1000,
        );
        cameraRef.camera.position.set(5, 5, 5);

        // Emit scene and camera for ChatPane
        // window.dispatchEvent(new CustomEvent('three-scene-ready', {
        //     detail: { scene, camera: cameraRef.camera }
        // }));

        renderer = new THREE.WebGLRenderer({
            canvas: canvasElement,
            antialias: true,
        });
        renderer.setSize(window.innerWidth, window.innerHeight);
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.PCFSoftShadowMap;
        // renderer.setPixelRatio(0.2)

        controls = new OrbitControls(cameraRef.camera, renderer.domElement);
        controls.enableDamping = true;
        controls.dampingFactor = 0.05;

        raycaster = new THREE.Raycaster();
        mouse = new THREE.Vector2();

        // Lighting
        const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
        scene.add(ambientLight);

        const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
        directionalLight.position.set(10, 10, 5);
        directionalLight.castShadow = true;
        directionalLight.shadow.mapSize.width = 2048;
        directionalLight.shadow.mapSize.height = 2048;
        directionalLight.shadow.camera.near = 0.5;
        directionalLight.shadow.camera.far = 50;
        directionalLight.shadow.camera.left = -10;
        directionalLight.shadow.camera.right = 10;
        directionalLight.shadow.camera.top = 10;
        directionalLight.shadow.camera.bottom = -10;
        scene.add(directionalLight);

        // Cone body
        const coneGeometry = new THREE.ConeGeometry(0.5, 1.5, 12);
        const coneMaterial = new THREE.MeshPhongMaterial({ color: 0x4169e1 });
        const cone = new THREE.Mesh(coneGeometry, coneMaterial);
        cone.position.y = 0.75;
        cone.castShadow = true;
        cone.receiveShadow = true;
        player.add(cone);

        // Sphere head
        const headGeometry = new THREE.SphereGeometry(0.4, 16, 16);
        const headMaterial = new THREE.MeshPhongMaterial({ color: 0xffdbac });
        const head = new THREE.Mesh(headGeometry, headMaterial);
        head.position.y = 1.8;
        head.castShadow = true;
        head.receiveShadow = true;
        player.add(head);

        // // Left eye
        // const eyeGeometry = new THREE.SphereGeometry(0.1, 8, 8);
        // const eyeMaterial = new THREE.MeshPhongMaterial({ color: 0x000000 });
        // const leftEye = new THREE.Mesh(eyeGeometry, eyeMaterial);
        // leftEye.position.set(-0.15, 1.85, 0.35);
        // leftEye.castShadow = true;
        // player.add(leftEye);
        //
        // // Right eye
        // const rightEye = new THREE.Mesh(eyeGeometry, eyeMaterial);
        // rightEye.position.set(0.15, 1.85, 0.35);
        // rightEye.castShadow = true;
        // player.add(rightEye);

        // Face sprite (expression system)
        const textureLoader = new THREE.TextureLoader();
        const faceTexture = textureLoader.load(facesUrl);
        faceTexture.repeat.set(1 / TOTAL_FACES, 1);
        faceTexture.offset.set(0, 0);
        faceTexture.colorSpace = THREE.SRGBColorSpace;
        faceTexture.minFilter = THREE.NearestFilter;
        faceTexture.magFilter = THREE.NearestFilter;

        faceMaterial = new THREE.MeshBasicMaterial({
            map: faceTexture,
            transparent: true,
            side: THREE.DoubleSide,
            // alphaTest: 0.5
        });
        const planeGeo1 = new THREE.PlaneGeometry(1, 1);
        facePlane = new THREE.Mesh(planeGeo1, faceMaterial);
        facePlane.position.set(0, 1.8, 0.4);
        facePlane.scale.set(0.6, 0.6, 1);
        // facePlane.castShadow=true;
        // facePlane.receiveShadow=false;
        player.add(facePlane);

        player.position.set(0, 0, 0);
        scene.add(player);

        const curve = new THREE.CatmullRomCurve3([
            new THREE.Vector3(-1, 0, 1),
            new THREE.Vector3(-0.5, 0.5, 0.5),
            new THREE.Vector3(0, 0, 0),
            new THREE.Vector3(0.5, -0.5, 0.5),
            new THREE.Vector3(1, 0, 1),
        ]);

        // 2. Create the Tube (path, segments, radius, radialSegments, closed)
        const geometry = new THREE.TubeGeometry(curve, 16, 0.1, 6, false);
        const material = new THREE.MeshStandardMaterial({ color: 0xffd700 });
        const noodle = new THREE.Mesh(geometry, material);
        player.add(noodle);

        // Plane
        const planeGeometry = new THREE.PlaneGeometry(20, 20);
        const planeMaterial = new THREE.MeshPhongMaterial({
            color: 0x90ee90,
            side: THREE.DoubleSide,
        });
        plane = new THREE.Mesh(planeGeometry, planeMaterial);
        plane.rotation.x = -PI / 2;
        plane.position.y = 0;
        plane.receiveShadow = true;
        scene.add(plane);

        const handlePointerDown = (event: PointerEvent) => {
            clickStartTime = Date.now();
            hasMoved = false;
            isDragging = false;
            event.pointerId;
        };

        const handlePointerMove = () => {
            if (clickStartTime) {
                hasMoved = true;
                if (Date.now() - clickStartTime > 100) {
                    isDragging = true;
                }
            }
        };

        const handlePointerUp = (event: PointerEvent) => {
            const clickDuration = Date.now() - clickStartTime;

            // Only trigger movement for quick clicks (< 1ms or < 50ms) without movement
            if (!isDragging) {
                // clickDuration < 150 &&

                // Calculate mouse position
                const rect = canvasElement.getBoundingClientRect();
                mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
                mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

                raycaster.setFromCamera(mouse, cameraRef.camera);

                const intersects = raycaster.intersectObject(plane);

                if (intersects.length > 0) {
                    const point = intersects[0].point;

                    movePoints.push(point);
                }
            }

            clickStartTime = 0;
            hasMoved = false;
            isDragging = false;
        };

        renderer.domElement.addEventListener("pointerdown", handlePointerDown);
        renderer.domElement.addEventListener("pointermove", handlePointerMove);
        renderer.domElement.addEventListener("pointerup", handlePointerUp);

        // Animation loop
        const animate = () => {
            animationId = requestAnimationFrame(animate);

            move();

            // Update face sprite texture offset based on current face
            if (faceMaterial && faceMaterial.map) {
                faceMaterial.map.offset.x = faceState.currentFace / TOTAL_FACES;
                // faceMaterial.alphaMap.offset.x = faceMaterial.map.offset.x;
            }

            controls.update();
            renderer.render(scene, cameraRef.camera);
        };

        const move = () => {
            const current = movePoints[0];
            if (current) {
                const speed = 0.1;
                const dx = current.x - player.position.x;
                const dy = current.z - player.position.z;
                const r = Math.sqrt(dx * dx + dy * dy);
                player.rotation.y = Math.atan2(dy, -dx) - PI / 2;
                if (r < speed * 2) {
                    // @ts-expect-error
                    player.position.copy(movePoints.shift());
                } else {
                    player.position.x += (speed * dx) / r;
                    player.position.z += (speed * dy) / r;
                }
            }
        };

        animate();

        // Handle window resize
        const handleResize = () => {
            cameraRef.camera.aspect = window.innerWidth / window.innerHeight;
            cameraRef.camera.updateProjectionMatrix();
            renderer.setSize(window.innerWidth, window.innerHeight);
        };

        window.addEventListener("resize", handleResize);
    });

    onDestroy(() => {
        if (animationId) {
            cancelAnimationFrame(animationId);
        }
        if (renderer) {
            renderer.domElement.removeEventListener("pointerdown", () => {});
            renderer.domElement.removeEventListener("pointermove", () => {});
            renderer.domElement.removeEventListener("pointerup", () => {});
            renderer.dispose();
        }
        window.removeEventListener("resize", () => {});
    });
</script>

<canvas bind:this={canvasElement} class="w-full h-screen block"></canvas>
