// import { useState, useEffect } from "react";
import { createClient  } from "@supabase/supabase-js";
// import { Auth } from "@supabase/auth-ui-react";
// import { ThemeSupa } from "@supabase/auth-ui-shared";

const supabase = createClient(
  "https://djogasoslhmlflrugdds.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRqb2dhc29zbGhtbGZscnVnZGRzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzA2ODEwOTEsImV4cCI6MjA0NjI1NzA5MX0.xgC_ydtdCzjoC__pnRmcpDFnDN0rv_T4v73YmzFT5EA",
);

// async function requestTable() {
//   const { data, error } = await supabase.from("user").select("*").limit(100)
//   if(error){
//       console.error(error)
//   }else
//   console.log(data)
// }

async function ins(){
const { data, error } = await supabase.from("user_pending").select('*')

    // insert({id:"affb51e9-98fc-46c0-b7be-618cbbc02c12",first_name:'nn',last_name:'mm'})
  if(error){
      console.error(error)
  }else
  console.log(data)
}

export default function Login() {
  // const [session, setSession] = useState<Session | null>(null);
  // useEffect(() => {
  //   supabase.auth.getSession().then(({ data: { session } }) => {
  //     setSession(session);
  //   });
  //
  //   const {
  //     data: { subscription },
  //   } = supabase.auth.onAuthStateChange((_event, session) => {
  //     setSession(session);
  //   });
  //
  //   return () => subscription.unsubscribe();
  // }, []);
  //
  // if (!session) {
  //   return <Auth supabaseClient={supabase} appearance={{ theme: ThemeSupa }} />;
  // } else {
  //   return (
  //     <div className="flex items-center bg-red-300 h-screen">
  //       <div>LoggedIn</div>
  //       <button onClick={requestTable}>Get</button>
  //     </div>
  //   );
  // }
    return(

      <div className="flex items-center bg-red-300 h-screen">
        <div>LoggedIn</div>
        <button onClick={ins}>Get</button>
      </div>
    )
}
