## 2.0.8
- 重构服务

## 1.0.15

- ChatCompletion 改进回调解析，不再强制要求 model

## 1.0.14

- ChatCompletion 改进回调解析，不再强制要求 created

## 1.0.13

- ChatManager 新增header属性，可以自由定义3

## 1.0.12

- ChatManager 新增header属性，可以自由定义2

## 1.0.11

- ChatManager 新增header属性，可以自由定义

## 1.0.10

- 补充ChatManager的onHeader方法

## 1.0.9

- 所有OpenAI的接口均增加onHeader方法，用于解析响应Header

## 1.0.8

- 修复 chatWithTools 方法的请求返回值解析问题

## 1.0.7

- 修复 chat 方法的请求返回值解析问题

## 1.0.6

- 新增标题生成方法

## 1.0.5

- 添加更详细的 Json 导出字段
- ChatManager 添加 importMessage 方法
- ChatMessage 添加 status 字段用来判断消息状态

## 1.0.4

- 只要是在流式输出，就会加入一个空消息，可以结合 stream 和空内容展示加载状态。

## 1.0.3

- FunctionTool 增加 title, with_property 属性

## 1.0.2

- 修复 ToolCall 转换到 ChatMessageItem 后的遗漏问题

## 1.0.1

- ToolCall 增加 Name，方便查找和使用

## 1.0.0

- 改进图片显示

## 0.0.1

- 完成初始版本
