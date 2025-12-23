<script lang="ts">
  import { onMount } from "svelte";
  import { create } from "./instance";
  import type { Vector3 } from "three";

  export let width = window.innerWidth;
  export let height = window.innerHeight;
  export let point: Vector3;

  let element: HTMLCanvasElement;

  onMount(() => {
    element.width = width;
    element.height = height;
    console.log(element.width, element.height);
    create(element, (p: Vector3) => {
      point.x = Math.round(p.x * 100) / 100;
      point.y = Math.round(p.y * 100) / 100;
      point.z = Math.round(p.z * 100) / 100;
    });
  });
</script>

<canvas bind:this={element} class="rounded-md"></canvas>
