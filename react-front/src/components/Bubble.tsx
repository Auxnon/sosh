
import {genLorem} from "../utils/lorem.js";

// function r(){
//     return Math.floor(20+Math.random()*30)
// }

// function genBorder(){
//     return `${r()}% ${r()}% ${r()}% ${r()}% / ${r()}% ${r()}% ${r()}% ${r()}%`
// }

const Bubble=()=><div className="bg-blue-500 rounded-lg my-2" >{genLorem()}</div>
export default Bubble
