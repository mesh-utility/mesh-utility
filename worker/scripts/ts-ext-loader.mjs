/**
 * Node's type stripper does not resolve extensionless TypeScript imports.
 * The Worker source keeps those imports so Wrangler/esbuild can bundle them.
 */
export async function resolve(specifier, context, nextResolve) {
  if (
    (specifier.startsWith('./') || specifier.startsWith('../')) &&
    !/\.(?:[cm]?[jt]s|json)$/i.test(specifier)
  ) {
    return nextResolve(`${specifier}.ts`, context);
  }
  return nextResolve(specifier, context);
}
