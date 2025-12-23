<script lang="ts">
  import svelteLogo from "./assets/svelte.svg";
  import viteLogo from "/vite.svg";
  import Counter from "./lib/Counter.svelte";
  import Canvas from "./lib/Canvas.svelte";
  import ValueGradient from "./lib/ValueGradient.svelte";
  import { Vector3 } from "three";

  let point: Vector3 = new Vector3(1, 2, 3);
</script>

<div class="absolute w-full h-full">
  <Canvas bind:point />
</div>
<main class="absolute w-64">
  <h1 class="bg-red-500 rounded-md p-1">{point.z}</h1>
</main>
  <ValueGradient/>


<style>
  .logo {
    height: 6em;
    padding: 1.5em;
    will-change: filter;
    transition: filter 300ms;
  }
  .logo:hover {
    filter: drop-shadow(0 0 2em #646cffaa);
  }
  .logo.svelte:hover {
    filter: drop-shadow(0 0 2em #ff3e00aa);
  }
  .read-the-docs {
    color: #888;
  }
</style>
