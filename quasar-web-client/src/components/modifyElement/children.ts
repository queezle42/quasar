import type { Component, ComponentInitArguments, WireNode } from "../api"

type ChildrenCommand =
  | { fn: "insert", i: number, node: WireNode }
  | { fn: "append", node: WireNode }
  | { fn: "remove", i: number }
  | { fn: "replace", nodes: [WireNode] }

export const childrenComponent: Component = {
  type: "modifyElement",
  name: "children",
  init: (args) => {
    const initialWireNodes = args.initData as [WireNode];
    const initialNodes = initialWireNodes.map(wireNode => args.componentApi.createNode(wireNode));
    args.target.replaceChildren(...initialNodes);

    return {
      initConnected: (_send) => {
        return {
          output: null,
          receive: (updateData) => receive(args, updateData)
        };
      },
      initStatic: () => {
        return null;
      },
    };
  },
}

function receive(args: ComponentInitArguments<HTMLElement>, updateData: unknown) {
  const element = args.target;
  const command = updateData as ChildrenCommand;
  switch (command.fn) {
    case "insert":
      {
        const target = element.childNodes[command.i];
        if (!target) {
          throw `[quasar-web] List index ${command.i} out of bounds`;
        }
        const newNode = args.componentApi.createNode(command.node);
        target.before(newNode);
      }
      break;
    case "append":
      {
        const newNode = args.componentApi.createNode(command.node);
        element.append(newNode);
      }
      break;
    case "remove":
      {
        const target = element.childNodes[command.i];
        if (!target) {
          throw `[quasar-web] List index ${command.i} out of bounds`;
        }
        target.remove();
      }
      break;
    case "replace":
      {
        const nodes = command.nodes.map(wireNode => args.componentApi.createNode(wireNode));
        element.replaceChildren(...nodes);
      }
      break;
  };
}
