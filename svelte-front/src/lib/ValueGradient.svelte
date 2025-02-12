<script lang="ts">
    import { onMount } from "svelte";

    // export let width = window.innerWidth;
    // export let height = window.innerHeight;
    // export let point: Vector3;

    let element: HTMLCanvasElement;
    let picks: HTMLElement[] = [];
    let points: number[] = [10, 100, 190];
    let pick=-1
    const THRESHOLD = 10;
    let m = { x: 0, y: 0 };
    let ctx!: CanvasRenderingContext2D;

    onMount(() => {
        // element.width = window.innerWidth;
        // element.height = window.innerHeight;
        console.log(element.width, element.height);
        ctx = element.getContext("2d");
        if (!ctx) return;
        ctx.lineWidth = 10;
        ctx.fillRect(0, 0, 10, 10);

        // create(element, (p: Vector3) => {
        //   point.x = Math.round(p.x * 100) / 100;
        //   point.y = Math.round(p.y * 100) / 100;
        //   point.z = Math.round(p.z * 100) / 100;
        // });

        // ctx.beginPath();
        // ctx.moveTo(50, 140);
        // ctx.lineTo(150, 60);
        // ctx.lineTo(250, 140);
        // ctx.closePath();
        // ctx.stroke()
    });

    function mouseDown(event: MouseEvent) {
        // m.x=event.screenX
        // m.y=event.screenY
        const c = element as HTMLElement;
        const p = c.parentElement as HTMLElement;
        const rect = c.getBoundingClientRect();
        const prect = p.getBoundingClientRect();
        m.x = event.clientX - rect.left;
        m.y = event.clientY - rect.top;
         pick = getPoint(m.x);
        if (pick > -1) {
            points[pick] = m.x;
        }
        // refresh();
    }

    function getPoint(x: number): number {
        let c = THRESHOLD;
        let i: number = -1;
        points.forEach((p, it) => {
            const v = Math.abs(p - x);
            if (v < c) {
                c = v;
                i = it;
            }
        });
        return i;
    }

    function refresh(): void {
        ctx.clearRect(0, 0, element.width, element.height);
        // ctx.beginPath();
        // ctx.moveTo(0, 0);
        // ctx.lineTo(m.x, m.y);
        // ctx.closePath();
        ctx.fillRect(0, 0, m.x, m.y);
        ctx.stroke();
    }
</script>

<div
    class="bg-white w-64 h-64 absolute left-1/2 bottom-0 rounded-md"
    style="transform: translateX(-50%)"
>
    {#each points as x, i}
        <li
            class="bg-blue-100 absolute p-2 rounded-md"
            bind:this={picks[i]}
            style:left={x + "px"}
        >
            hi {i + 1}
        </li>
    {/each}
    <canvas
        bind:this={element}
        on:mousedown={mouseDown}
        class="rounded-md relative bg-green-200 w-auto h-32 mx-auto mt-4 bottom-0"
    ></canvas>
</div>
