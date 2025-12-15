<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import * as THREE from 'three';
	import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

	let canvasElement: HTMLCanvasElement;
	let scene: THREE.Scene;
	let camera: THREE.PerspectiveCamera;
	let renderer: THREE.WebGLRenderer;
	let controls: OrbitControls;
	let animationId: number;
	let playerGroup: THREE.Group;

	onMount(() => {
		if (!canvasElement) return;

		// Scene setup
		scene = new THREE.Scene();
		scene.background = new THREE.Color(0x87ceeb);

		// Camera setup
		camera = new THREE.PerspectiveCamera(
			75,
			window.innerWidth / window.innerHeight,
			0.1,
			1000
		);
		camera.position.set(5, 5, 5);

		// Renderer setup
		renderer = new THREE.WebGLRenderer({ canvas: canvasElement, antialias: true });
		renderer.setSize(window.innerWidth, window.innerHeight);
		renderer.shadowMap.enabled = true;
		renderer.shadowMap.type = THREE.PCFSoftShadowMap;

		// Controls
		controls = new OrbitControls(camera, renderer.domElement);
		controls.enableDamping = true;
		controls.dampingFactor = 0.05;
        controls.

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

		// Create player model
		playerGroup = new THREE.Group();

		// Cone body
		const coneGeometry = new THREE.ConeGeometry(0.5, 1.5, 8);
		const coneMaterial = new THREE.MeshPhongMaterial({ color: 0x4169e1 });
		const cone = new THREE.Mesh(coneGeometry, coneMaterial);
		cone.position.y = 0.75;
		cone.castShadow = true;
		cone.receiveShadow = true;
		playerGroup.add(cone);

		// Sphere head
		const headGeometry = new THREE.SphereGeometry(0.4, 16, 16);
		const headMaterial = new THREE.MeshPhongMaterial({ color: 0xffdbac });
		const head = new THREE.Mesh(headGeometry, headMaterial);
		head.position.y = 1.8;
		head.castShadow = true;
		head.receiveShadow = true;
		playerGroup.add(head);

		// Left eye
		const eyeGeometry = new THREE.SphereGeometry(0.1, 8, 8);
		const eyeMaterial = new THREE.MeshPhongMaterial({ color: 0x000000 });
		const leftEye = new THREE.Mesh(eyeGeometry, eyeMaterial);
		leftEye.position.set(-0.15, 1.85, 0.35);
		leftEye.castShadow = true;
		playerGroup.add(leftEye);

		// Right eye
		const rightEye = new THREE.Mesh(eyeGeometry, eyeMaterial);
		rightEye.position.set(0.15, 1.85, 0.35);
		rightEye.castShadow = true;
		playerGroup.add(rightEye);

		playerGroup.position.set(0, 0, 0);
		scene.add(playerGroup);

		// Plane
		const planeGeometry = new THREE.PlaneGeometry(20, 20);
		const planeMaterial = new THREE.MeshPhongMaterial({ 
			color: 0x90ee90,
			side: THREE.DoubleSide 
		});
		const plane = new THREE.Mesh(planeGeometry, planeMaterial);
		plane.rotation.x = -Math.PI / 2;
		plane.position.y = 0;
		plane.receiveShadow = true;
		scene.add(plane);

		// Animation loop
		const animate = () => {
			animationId = requestAnimationFrame(animate);

			// Rotate player
			playerGroup.rotation.y += 0.01;

			controls.update();
			renderer.render(scene, camera);
		};

		animate();

		// Handle window resize
		const handleResize = () => {
			camera.aspect = window.innerWidth / window.innerHeight;
			camera.updateProjectionMatrix();
			renderer.setSize(window.innerWidth, window.innerHeight);
		};

		window.addEventListener('resize', handleResize);
	});

	onDestroy(() => {
		if (animationId) {
			cancelAnimationFrame(animationId);
		}
		if (renderer) {
			renderer.dispose();
		}
		window.removeEventListener('resize', () => {});
	});
</script>

<canvas bind:this={canvasElement} class="w-full h-screen block"></canvas>
