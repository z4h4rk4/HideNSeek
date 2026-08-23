--!strict

return table.freeze({
	REMOTE_NAME = "SkinCaseRemote",

	CHARACTERS_FOLDER_NAME = "Characters",
	STARTER_PACK_FOLDER_NAME = "StarterPack",

	SKIN_SHOP_GUI_NAME = "SkinShopGui",
	SKINS_MAIN_FRAME_NAME = "SkinsMainFrame",
	YOU_SCROLLING_FRAME_NAME = "YouScrollingFrame",
	CARD_STARTER_PACK_NAME = "CardStarterPack",
	COIN_BUY_BUTTON_NAME = "CoinBuyBtn",
	COIN_PRICE_LABEL_NAME = "CoinPrice",
	ROBUX_BUTTON_NAME = "RobuxBtn",
	PLUS_BUTTON_NAME = "PlusBtn",
	MINUS_BUTTON_NAME = "MinusBtn",

	CASE_OPENING_GUI_NAME = "CaseOpeningGui",
	CASE_OPENING_MAIN_FRAME_NAME = "MainFrame",
	CASE_OPENING_CASE_NAME = "Case",
	CASE_OPENING_CHARACTER_NAME = "Character",
	CASE_OPENING_RAYS_NAME = "Rays",
	CASE_OPENING_BLUR_NAME = "CaseOpeningBlur",
	CASE_OPENING_CLICK_COUNT = 3,
	CASE_OPENING_REVEAL_SECONDS = 1.6,
	CASE_OPENING_BIND_TIMEOUT_SECONDS = 20,
	CASE_OPENING_BLUR_SIZE = 18,
	HUB_CASE_SELLER_PROMPT_NAME = "CaseShopPrompt",
	HUB_CASE_SELLER_PROMPT_ATTRIBUTE = "OpensSkinCaseShop",

	STARTER_PACK_CASE_ID = "StarterPack",
	STARTER_PACK_COIN_PRICE = 300,
	STARTER_PACK_ROBUX_PRODUCT_ID = 3709349075,
	MAX_COIN_OPEN_QUANTITY = 10,
	UI_BIND_TIMEOUT_SECONDS = 20,

	RARITY_BACKGROUND_IMAGES = table.freeze({
		Common = "rbxassetid://89111839103799",
		Rare = "rbxassetid://131307111782580",
		Mystic = "rbxassetid://70823685869578",
		Legend = "rbxassetid://127987363974859",
	}),

	SKIN_IMAGES = table.freeze({
		BlueCharacter = "rbxassetid://93791535966082",
		VelvetCharacter = "rbxassetid://99431952495806",
		GreenTShirt = "rbxassetid://92281003438761",
		Sheriff = "rbxassetid://128685680749566",
		SuitLegend = "rbxassetid://131235524467546",
		SuperGuy = "rbxassetid://124258148287784",
	}),

	RARITIES = table.freeze({
		Common = table.freeze({
			DisplayName = "Common",
			DuplicateCoins = 100,
		}),
		Rare = table.freeze({
			DisplayName = "Rare",
			DuplicateCoins = 250,
		}),
		Legend = table.freeze({
			DisplayName = "Legend",
			DuplicateCoins = 1000,
		}),
		Mystic = table.freeze({
			DisplayName = "Mystic",
			DuplicateCoins = 2500,
		}),
	}),

	CASES = table.freeze({
		StarterPack = table.freeze({
			Id = "StarterPack",
			DisplayName = "Starter Pack",
			CoinPrice = 300,
			RobuxProductId = 3709349075,
			Skins = table.freeze({
				table.freeze({
					Id = "BlueCharacter",
					DisplayName = "Blue Character",
					Rarity = "Common",
					Weight = 50,
				}),
				table.freeze({
					Id = "VelvetCharacter",
					DisplayName = "Velvet Character",
					Rarity = "Common",
					Weight = 50,
				}),
				table.freeze({
					Id = "GreenTShirt",
					DisplayName = "Green T-Shirt",
					Rarity = "Rare",
					Weight = 25,
				}),
				table.freeze({
					Id = "Sheriff",
					DisplayName = "Sheriff",
					Rarity = "Rare",
					Weight = 25,
				}),
				table.freeze({
					Id = "SuitLegend",
					DisplayName = "Suit Legend",
					Rarity = "Legend",
					Weight = 2,
				}),
				table.freeze({
					Id = "SuperGuy",
					DisplayName = "Super Guy",
					Rarity = "Mystic",
					Weight = 10,
				}),
			}),
		}),
	}),
})
