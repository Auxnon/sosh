
// import {genLorem} from "../utils/lorem.js";

import { Message, MessageCategory } from "../utils/types"

// function r(){
//     return Math.floor(20+Math.random()*30)
// }

// function genBorder(){
//     return `${r()}% ${r()}% ${r()}% ${r()}% / ${r()}% ${r()}% ${r()}% ${r()}%`
// }

function getColor(c: MessageCategory):string{
    switch(c){
        case MessageCategory.Data: return "bg-red-200"
        case MessageCategory.User: return "bg-blue-500"
        default: return "bg-green-500"
    }
}

const Bubble=({message}:{message:Message})=><div className={`${getColor(message.category)} rounded-lg my-2`} >{message.user+":"+message.value}</div>
export default Bubble
