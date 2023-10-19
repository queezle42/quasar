import type { Component, WireComponent } from "../api"

type WireElement = {
  tag: string,
  components: [WireComponent<HTMLElement, null>],
}

export const elementComponent: Component = {
  type: "createNode",
  name: "element",
  init: (args) => {
    const wireElement = args.initData as WireElement;
    const element = document.createElement(wireElement.tag);

    for (let wireComponent of wireElement.components) {
      args.componentApi.attachModifyElementComponent(wireComponent, element);
    }

    return {
      initConnected: (_send) => {
        return { output: element };
      },
      initStatic: () => {
        return element;
      }
    };
  }
}
