import { Component } from "./api"
import { elementComponent } from "./createNode/element";
import { textNodeComponent } from "./createNode/text"
import { childrenComponent } from "./modifyElement/children";

export const coreComponents: readonly Component[] = [
  elementComponent,
  textNodeComponent,
  childrenComponent,
];
