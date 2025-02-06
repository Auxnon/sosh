/** @type {import('tailwindcss').Config} */
export default {
    corePlugins:{
        preflight: false,
    },
  content: [
      "./index.html",
      "./src/**/*.{js,jsx,ts,tsx}",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
     // prefix: 'tw-',
}
