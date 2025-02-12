export enum MessageCategory {
  System = 0,
  Data = 1,
  User = 2,
}

export interface Message {
  user: string;
  category: MessageCategory;
  value: string;
}
