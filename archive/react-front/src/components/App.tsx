import { useState, useRef, useEffect } from "react";
import "./App.css";
import Pane from "./Pane";
import WorldPane from "./WorldPane";
import Login from "./Login";
import Drawer from "./Drawer";
import { MessageCategory } from "../utils/types";
import { join, sendChat, testChat } from "../world/connection";
import { errorIn } from "../world/error";

function App() {
  const [count, setCount] = useState(0);
  const [error, setError] = useState("");
  const [chat, setChat] = useState([
    { user: "", value: "one", category: MessageCategory.System },
  ]);
  const inputRef = useRef<HTMLInputElement>(null);
  // const messageRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    errorIn((message, err) => {
      console.error(err);
      setError(message);
    });
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
      <h1 className="bg-red-500 rounded-md">Test3</h1>
      <WorldPane></WorldPane>
      <div></div>
      <Pane chat={chat}></Pane>
      <Login></Login>
      <input type="text" ref={inputRef} />
      <div className="card">
        <button onClick={() => setCount((count) => count + 1)}>
          count is {count}
        </button>
      </div>
      {!!error && (
        <div
          className="h-screen w-screen fixed left-0 top-0 text-center"
          style={{ background: "#ffaaaa55" }}
        >
          <h1 className="text-amber-500 p-10 bg-red-100">Yikes!</h1>
          <h1 className="text-amber-500 p-10 bg-red-100">{error}</h1>
        </div>
      )}
    </>
  );
}

export default App;
