import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The app imports the backtest evidence from ../docs, outside the app folder.
export default defineConfig({ plugins: [react()], server: { fs: { allow: [".."] } } });
