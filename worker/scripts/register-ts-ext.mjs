import { register } from 'node:module';

await register('./ts-ext-loader.mjs', import.meta.url);
