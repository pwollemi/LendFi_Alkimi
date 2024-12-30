# Alkimi Liquidation bot

```
      ,,       ,,  ,,    ,,,    ,,   ,,,      ,,,    ,,,   ,,,          ,,,
     ███▄     ██  ███▀▀▀███▄   ██▄██▀▀██▄    ██▌     ██▌  ██▌        ▄▄███▄▄
    █████,   ██  ██▌          ██▌     └██▌  ██▌     ██▌  ██▌        ╟█   ╙██
    ██ └███ ██  ██▌└██╟██   l███▀▄███╟█    ██      ╟██  ╟█i        ▐█▌█▀▄██╟
   ██   ╙████  ██▌          ██▌     ,██▀   ╙██    ▄█▀  ██▌        ▐█▌    ██
  ██     ╙██  █████▀▀▄██▀  ██▌██▌╙███▀`     ▀██▄██▌   █████▀▄██▀ ▐█▌    ██╟
 ¬─      ¬─   ¬─¬─  ¬─¬─'  ¬─¬─¬─¬ ¬─'       ¬─¬─    '¬─   '─¬   ¬─     ¬─'
```

## Introduction

This liquidaton bot is a starting point for the community members interested in arbitrage opportunities with Alkimi. It uses Balancer flash loans to purchase discounted collateral assets from underwater accounts.

## Liquidator logic

The liquidation bot executes the following actions:

1. Borrows base token from a Balancer vault using flashswap functionality.
2. Liquidates an underwater account by repaying the loan.
3. Recieves discounted collateral from protocol.
4. Exchanges collateral assets into base token using UniswapV3.
5. Pays back flash loan.
6. Withdraws the profit.

## Disclaimer

This liquidator is supplied as is without any guaratees whatsoever. Use at your own risk.

## Important Information

You need to hold 20_000 governance tokens to be able to run liquidations on Alkimi

For documentation of Uniswap Flash Swaps, see [uniswap/flash-swaps](https://docs.uniswap.org/protocol/guides/flash-integrations/inheritance-constructors).

For documentation of Balancer Flash Swaps, see [balancer/flash-swaps](https://docs.balancer.fi/reference/contracts/flash-loans.html).
