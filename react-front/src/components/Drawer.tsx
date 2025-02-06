import { useEffect, useState } from "react";

interface Point {
  x: number;
  y: number;
}
export default function Drawer({ p }: { p: Point }) {
  // const t=p.x
  const [points, setPoints] = useState("m0 0L10 10L5 10Z");
  useEffect(() => {
    if (p) {
      const line = `m0 0L10 10L${p.x} ${p.y}Z`;
      setPoints(line);
    }
  }, [p]);
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className="w-screen scale-200 absolute inset-0"
    >
      <path d={points} stroke="black" fill="red" />
    </svg>
  );
}
