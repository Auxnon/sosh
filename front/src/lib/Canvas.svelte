<script lang="ts">
  import { onMount } from "svelte";
  import { create } from "./instance";

  export let width = window.innerWidth;
  export let height = window.innerHeight;

  let element: HTMLCanvasElement;

  onMount(() => {
    element.width = width;
    element.height = height;
    console.log(element.width, element.height);
    create(element);
  });
</script>

<canvas bind:this={element} class="rounded-md"></canvas>
