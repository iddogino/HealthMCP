import { sites } from '@openai/sites-vite-plugin';
import tailwindcss from '@tailwindcss/postcss';
import vinext from 'vinext';
import { defineConfig } from 'vite';
// This marketing site exports static files to the owner's Cloudflare account.
export default defineConfig({
  css:{postcss:{plugins:[tailwindcss()]}},
  server:process.env.CODEX_SANDBOX === 'seatbelt' ? {watch:{useFsEvents:false,usePolling:true}} : undefined,
  plugins:[vinext(),sites()],
});
