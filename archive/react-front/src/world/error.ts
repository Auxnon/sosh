const ERRO = "SoshError";

export function errorIn(func: (message: string, err:Error) => void) {
  document.addEventListener(ERRO, (ev) => {
    if (ev instanceof ErrorEvent) func(ev.message,ev.error);
  });
}

export function errorOut(message: string) {
  const error = new Error(message);
  const e = new ErrorEvent(ERRO, { error, message });
  document.dispatchEvent(e);
}
