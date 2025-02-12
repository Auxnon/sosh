import { useState, useRef, useEffect } from "react";
import "./App.css";
import Pane from "./Pane";
import WorldPane from "./WorldPane";
import Login from "./Login";
import Drawer from "./Drawer";
import { MessageCategory } from "../utils/types";
import { join, sendChat, testChat } from "../world/connection";

function App() {
  const [count, setCount] = useState(0);
  const [chat, setChat] = useState([
    { user: "", value: "one", category: MessageCategory.System },
  ]);
  const inputRef = useRef<HTMLInputElement>(null);
  // const messageRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    join(chat, setChat);

    inputRef.current?.addEventListener("keypress", (event: KeyboardEvent) => {
      if (event.key === "Enter") {
        sendChat(inputRef.current?.value ?? "NA");
        if (inputRef.current) inputRef.current.value = "";
      } else if (event.key === "\\") {
        console.log("update numbers");
        testChat();
        return false;
      }
      console.log(event.key);
    });
  }, []);

  return (
    <>
      {/* this is weird pheonix bug hack fix for firefox only */}
      <script>0</script> <Drawer p={{ x: 10, y: 20 }}></Drawer>
      <h1 className="bg-red-500 rounded-md">Test</h1>
      <WorldPane></WorldPane>
      <Login></Login>
      <div></div>
      <Pane chat={chat}></Pane>
      <input type="text" ref={inputRef} />
      <div className="card">
        <button onClick={() => setCount((count) => count + 1)}>
          count is {count}
        </button>
        <p>
          Edit <code>src/App.tsx</code> and save to test HMR
        </p>
      </div>
      <p className="read-the-docs">
        Click on the Vite and React logos to learn more
      </p>
    </>
  );
}

export default App;
