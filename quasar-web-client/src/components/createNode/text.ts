import type { Component } from "../api"

export const textNodeComponent: Component = {
  type: "createNode",
  name: "text",
  init: (args) => {
    const textNode = document.createTextNode(args.initData as string);
    return {
      initConnected: (_send) => {
        const receive = (updateData: unknown) => textNode.data = updateData as string;
        return { output: textNode, receive };
      },
      initStatic: () => {
        return textNode;
      }
    };
  }
}
