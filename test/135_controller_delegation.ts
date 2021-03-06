// @ts-ignore
import helper from 'ganache-time-traveler'
// @ts-ignore
import { expectRevert } from '@openzeppelin/test-helpers'
import { WETH, rate1, daiTokens1, wethTokens1, bnify } from './shared/utils'
import { MakerEnvironment, YieldEnvironmentLite, Contract } from './shared/fixtures'

contract('Controller - Delegation', async (accounts) => {
  let [user1, user2] = accounts

  let snapshot: any
  let snapshotId: string
  let maker: MakerEnvironment
  let env: YieldEnvironmentLite

  let weth: Contract
  let dai: Contract
  let treasury: Contract
  let controller: Contract
  let fyDai1: Contract

  let maturity1: number
  let maturity2: number

  beforeEach(async () => {
    snapshot = await helper.takeSnapshot()
    snapshotId = snapshot['result']

    // Setup fyDai
    const block = await web3.eth.getBlockNumber()
    maturity1 = (await web3.eth.getBlock(block)).timestamp + 1000
    maturity2 = (await web3.eth.getBlock(block)).timestamp + 2000

    env = await YieldEnvironmentLite.setup([maturity1, maturity2])
    maker = env.maker
    controller = env.controller
    treasury = env.treasury
    weth = env.maker.weth
    dai = env.maker.dai
    fyDai1 = env.fyDais[0]
  })

  afterEach(async () => {
    await helper.revertToSnapshot(snapshotId)
  })

  it("doesn't allow to post from others if not a delegate", async () => {
    await expectRevert(
      controller.post(WETH, user1, user2, daiTokens1, { from: user2 }),
      'Controller: Only Holder Or Delegate'
    )
  })

  it('allows delegates to post weth from others', async () => {
    assert.equal(await controller.posted(WETH, user2), 0, 'User2 has posted collateral')

    await weth.deposit({ from: user1, value: wethTokens1 })
    await controller.addDelegate(user2, { from: user1 })
    await weth.approve(treasury.address, wethTokens1, { from: user1 })
    await controller.post(WETH, user1, user2, wethTokens1, { from: user2 })

    assert.equal(
      await controller.posted(WETH, user2),
      wethTokens1,
      'User2 should have ' + wethTokens1 + ' weth posted, instead has ' + (await controller.posted(WETH, user2))
    )
  })

  describe('with posted weth', () => {
    beforeEach(async () => {
      await weth.deposit({ from: user1, value: wethTokens1 })
      await weth.approve(treasury.address, wethTokens1, { from: user1 })
      await controller.post(WETH, user1, user1, wethTokens1, { from: user1 })

      await weth.deposit({ from: user2, value: wethTokens1 })
      await weth.approve(treasury.address, wethTokens1, { from: user2 })
      await controller.post(WETH, user2, user2, wethTokens1, { from: user2 })
    })

    it("doesn't allow to withdraw from others if not a delegate", async () => {
      await expectRevert(
        controller.withdraw(WETH, user1, user2, wethTokens1, { from: user2 }),
        'Controller: Only Holder Or Delegate'
      )
    })

    it('allows to withdraw weth from others', async () => {
      await controller.addDelegate(user2, { from: user1 })
      await controller.withdraw(WETH, user1, user2, wethTokens1, { from: user2 })

      assert.equal(await weth.balanceOf(user2), wethTokens1, 'User2 should have collateral in hand')
      assert.equal(await controller.powerOf(WETH, user1), 0, 'User1 should not have borrowing power')
    })

    it("doesn't allow to borrow fyDai from others if not a delegate", async () => {
      await expectRevert(
        controller.borrow(WETH, maturity1, user1, user2, daiTokens1, { from: user2 }),
        'Controller: Only Holder Or Delegate'
      )
    })

    it('allows to borrow fyDai from others', async () => {
      await controller.addDelegate(user2, { from: user1 })
      const toBorrow = (await controller.powerOf(WETH, user1)).toString()
      await controller.borrow(WETH, maturity1, user1, user2, toBorrow, { from: user2 })

      assert.equal(await fyDai1.balanceOf(user2), toBorrow.toString(), 'User2 should have fyDai')
      assert.equal(await controller.debtDai(WETH, maturity1, user1), toBorrow.toString(), 'User1 should have debt')
    })

    describe('with borrowed fyDai', () => {
      beforeEach(async () => {
        let toBorrow = (await controller.powerOf(WETH, user1)).toString()
        await controller.borrow(WETH, maturity1, user1, user1, toBorrow, { from: user1 })
        toBorrow = (await controller.powerOf(WETH, user2)).toString()
        await controller.borrow(WETH, maturity1, user2, user2, toBorrow, { from: user2 })
      })

      describe('with borrowed fyDai from two series', () => {
        beforeEach(async () => {
          await weth.deposit({ from: user1, value: wethTokens1 })
          await weth.approve(treasury.address, wethTokens1, { from: user1 })
          await controller.post(WETH, user1, user1, wethTokens1, { from: user1 })
          let toBorrow = (await env.unlockedOf(WETH, user1)).toString()
          await controller.borrow(WETH, maturity2, user1, user1, toBorrow, { from: user1 })

          await weth.deposit({ from: user2, value: wethTokens1 })
          await weth.approve(treasury.address, wethTokens1, { from: user2 })
          await controller.post(WETH, user2, user2, wethTokens1, { from: user2 })
          toBorrow = (await env.unlockedOf(WETH, user2)).toString()
          await controller.borrow(WETH, maturity2, user2, user2, toBorrow, { from: user2 })
        })

        it("others need to be added as delegates to repay fyDai with others' funds", async () => {
          await expectRevert(
            controller.repayFYDai(WETH, maturity1, user1, user1, daiTokens1, { from: user2 }),
            'Controller: Only Holder Or Delegate'
          )
        })

        it('allows delegates to use funds to repay fyDai debts', async () => {
          await controller.addDelegate(user2, { from: user1 })
          await fyDai1.approve(treasury.address, daiTokens1, { from: user1 })
          await controller.repayFYDai(WETH, maturity1, user1, user1, daiTokens1, { from: user2 })

          assert.equal(await fyDai1.balanceOf(user1), 0, 'User1 should not have fyDai')
          assert.equal(await controller.debtDai(WETH, maturity1, user1), 0, 'User1 should not have debt')
        })

        it("others need to be added as delegates to repay dai with others' funds", async () => {
          await expectRevert(
            controller.repayDai(WETH, maturity1, user1, user1, daiTokens1, { from: user2 }),
            'Controller: Only Holder Or Delegate'
          )
        })

        it('allows delegates to use funds to repay dai debts', async () => {
          await maker.getDai(user1, daiTokens1, rate1)
          await controller.addDelegate(user2, { from: user1 })
          const debt = bnify(await controller.debtDai(WETH, maturity1, user1))
          const balance = bnify(await dai.balanceOf(user1))

          await dai.approve(treasury.address, daiTokens1, { from: user1 })
          await controller.repayDai(WETH, maturity1, user1, user1, daiTokens1, { from: user2 })

          assert.equal(await dai.balanceOf(user1), balance.sub(debt).toString(), 'User1 should not have fyDai')
          assert.equal(await controller.debtDai(WETH, maturity1, user1), 0, 'User1 should not have debt')
        })
      })
    })
  })
})
