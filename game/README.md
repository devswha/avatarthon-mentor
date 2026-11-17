# 별 모으기 장애물 달리기 (Avatarthon Star Obby)

출발 섬에서 트로피까지 4구역을 건너며 별 20개를 모으는 로블록스 장애물 달리기 게임입니다.

| 구역 | 내용 |
|---|---|
| 1구역 | 계단처럼 올라가는 발판 점프, 보너스 발판, 좁은 다리 |
| 2구역 | 🍄 버섯 트램펄린으로 높은 섬까지 튕겨 오르기 |
| 3구역 | 🔥 용암 위 좁은 다리, 밟으면 사라지는 유리 발판 |
| 4구역 | 🌀 회전 막대 뛰어넘기, ☁️ 구름 발판 → 🏆 골인 |

- 구역마다 체크포인트가 있고, 바다나 용암에 빠지면 마지막 체크포인트에서 다시 시작합니다.
- 화면 위에 모은 별, 지금 구역, 걸린 시간이 나옵니다. 골인하면 기록이 뜨고 "처음부터 다시 하기"를 누를 수 있습니다.
- 별은 사람마다 따로 모읍니다. 친구가 먹은 별도 내 화면에는 남아 있습니다.

## 파일

| 파일 | 하는 일 |
|---|---|
| `place/AvatarthonStarObby.rbxlx` | Studio에서 여는 게임 파일. 코스와 스크립트가 모두 들어 있다 |
| `src/shared/GameConfig.luau` | 숫자·색 설정. 버섯 점프 높이, 유리 발판 시간, 회전 속도 등을 여기서 바꾼다 |
| `src/server/GameServer.server.luau` | 게임 규칙. 별 모으기, 체크포인트, 용암, 사라지는 발판, 회전 막대 판정, 골인 |
| `src/server/BlenderProps.server.luau` | Blender로 만든 소품을 코스 곳곳에 붙인다 |
| `src/client/GameClient.client.luau` | 화면. 점수판, 별 회전, 버섯 튕기기, 회전 막대 움직임, 골인 화면 |
| `default.project.json` | (선택) Rojo로 스크립트만 동기화할 때 쓰는 프로젝트 파일. 코스는 `.rbxlx`에만 있다 |

`.rbxlx`는 파이썬 생성기 `tools/build_place.py`(표준 라이브러리만 사용)가 위 Luau 소스와 코스 배치를 합쳐 만듭니다. `.py`는 제출함에 넣을 수 없어서 원문을 `sessions/notes/code-place-generator.md`에 옮겨 두었습니다.

## Studio에서 열기

1. Roblox Studio에서 **File > Open from File**로 `place/AvatarthonStarObby.rbxlx`를 엽니다.
2. Blender 소품을 넣습니다: **File > Import 3D**로 레포의 `assets/blender/AvatarthonProps.fbx`를 고르고 Import.
   가져온 `AvatarthonProps` 모델은 Workspace에 그대로 두거나 ServerStorage로 옮깁니다.
3. **Play**를 누르면 `BlenderProps` 스크립트가 별·버섯·깃발·트로피·구름 자리에 Blender 소품을 붙입니다.
   소품을 안 넣어도 기본 파트로 만든 대체 모양으로 끝까지 플레이할 수 있습니다.
4. **File > Publish to Roblox**로 올리면 게임 주소가 생깁니다.

코스의 충돌(밟는 곳)은 Blender 메시가 아니라 보이지 않는 기본 파트가 맡습니다. 그래서 소품을 바꾸거나 빼도 난이도가 같습니다.
