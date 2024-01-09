{{ config(
	schema = 'nex_optimism',
	alias = 'perpetual_trades',
	partition_by = ['block_month'],
	materialized = 'incremental',
	file_format = 'delta',
	incremental_strategy = 'merge',
	unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index'],
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')]
	)
}}


{% set project_start_date = '2022-09-01' %}

WITH all_executed_positions AS (
	SELECT *, 
	'Open' AS trade_type
	FROM {{ source('nex_optimism', 'Vault_evt_IncreasePosition') }}
	WHERE evt_tx_hash IN ( SELECT evt_tx_hash FROM {{ source('nex_optimism', 'PositionRouter_evt_ExecuteIncreasePosition') }} )
		{% if not is_incremental() %}
		AND evt_block_time >= DATE '{{project_start_date}}'
		{% else %}
		AND {{ incremental_predicate('evt_block_time') }}
		{% endif %}

	UNION ALL

	SELECT *, 
	'Close' AS trade_type
	FROM {{ source('nex_optimism', 'Vault_evt_DecreasePosition') }}
	WHERE evt_tx_hash IN ( SELECT evt_tx_hash FROM {{ source('nex_optimism', 'PositionRouter_evt_ExecuteDecreasePosition') }} )
		{% if not is_incremental() %}
		AND evt_block_time >= DATE '{{project_start_date}}'
		{% else %}
		AND {{ incremental_predicate('evt_block_time') }}
		{% endif %}
),

margin_fees_info AS (
	SELECT *, 
	LEAD(evt_index, 1, 1000000) OVER (PARTITION BY evt_tx_hash ORDER BY evt_index) AS next_evt_index
	FROM {{ source('nex_optimism', 'Vault_evt_CollectMarginFees') }}
	{% if not is_incremental() %}
	WHERE evt_block_time >= DATE '{{project_start_date}}'
	{% else %}
	WHERE {{ incremental_predicate('evt_block_time') }}
	{% endif %}
),

complete_perp_tx AS (
	SELECT
		*
		, index_token || '/USD' AS market
	FROM 
	(
		SELECT
			event.account,
			event.contract_address,
			event.indexToken,
			event.sizeDelta,
			event.evt_block_time,
			event.evt_index,
			event.evt_tx_hash,
			event.isLong,
			event.collateralDelta,
			event.evt_tx_from,
			event.evt_tx_to,
            event.trade_type,
			tokens1.symbol AS underlying_asset,
			(
				CASE 
				WHEN tokens.symbol = 'WETH' THEN 'ETH'
				WHEN tokens.symbol = 'WBTC' THEN 'BTC'
				ELSE tokens.symbol
			END
			) AS index_token,
			fee.feeUsd AS margin_fee
		FROM all_executed_positions event
		INNER JOIN margin_fees_info fee
		ON event.evt_tx_hash = fee.evt_tx_hash
		AND event.evt_index >  fee.evt_index
		AND event.evt_index <  fee.next_evt_index
		INNER JOIN {{ ref('tokens_erc20') }} tokens
		ON event.indexToken = tokens.contract_address
		AND tokens.blockchain = 'optimism'
		INNER JOIN {{ ref('tokens_erc20') }} tokens1
		ON event.collateralToken = tokens1.contract_address
		AND tokens1.blockchain = 'optimism'
		GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	)
)

SELECT
	'optimism' AS blockchain
	,CAST(date_trunc('DAY', evt_block_time) AS date) AS block_date
	,CAST(date_trunc('MONTH', evt_block_time) AS date) AS block_month
	,evt_block_time AS block_time
	,CAST(NULL AS VARCHAR) AS virtual_asset
    ,underlying_asset
	,market
	,contract_address AS market_address
	,CAST(sizeDelta/1e30 AS DOUBLE) AS volume_usd
	,CAST(margin_fee/1e30 AS DOUBLE) fee_usd
	,CAST(collateralDelta/1e30 AS DOUBLE) AS margin_usd
	,(CASE
        WHEN isLong = false AND trade_type = 'Open' THEN 'Open Short'
        WHEN isLong = true AND trade_type = 'Open' THEN 'Open Long'
        WHEN isLong = false AND trade_type = 'Close' THEN 'Close Short'
        WHEN isLong = true AND trade_type = 'Close' THEN 'Close Long'
     END   
    ) AS trade
	,'NEX' AS project
	,'v1' AS version
	,'NEX' AS frontend
	,account AS trader
	,sizeDelta AS volume_raw
	,evt_tx_hash AS tx_hash
	,evt_tx_from AS tx_from
	,evt_tx_to AS tx_to
	,evt_index
FROM complete_perp_tx
