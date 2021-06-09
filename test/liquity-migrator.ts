import {ethers} from "hardhat";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import chaiBignumber from "chai-bn";
import {
    DSProxy,
    DSProxy__factory,
    DSProxyFactory__factory,
    DssProxyActions,
    DssProxyActions__factory,
    IERC20,
    IERC20__factory,
    MakerETHMigrator,
    MakerETHMigrator__factory,
    ManagerLike,
    ManagerLike__factory,
    VatLike,
    VatLike__factory
} from "../typechain";
import {BigNumber, utils} from "ethers";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";

chai
    .use(chaiBignumber(BigNumber))
    .use(chaiAsPromised);
const {expect} = chai;

describe("LiquityMigrator", () => {
    const ethJoin = "0x2F0b23f53734252Bda2277357e97e1517d6B042A";
    const daiJoin = "0x9759A6Ac90977b93B58547b4A71c78317f391A28";
    const uniswapFactory = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f";
    const daiAddress = "0x6b175474e89094c44da98b954eedeac495271d0f";
    const wethAddress = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
    let signer: SignerWithAddress
    let testObj: MakerETHMigrator;
    let proxy: DSProxy
    let manager: ManagerLike
    let cdpId: BigNumber
    let dai: IERC20
    let weth: IERC20
    let actions: DssProxyActions
    let urn: string;
    let vat: VatLike;

    before(async () => {
        const signers = await ethers.getSigners()
        signer = signers[0]
        manager = ManagerLike__factory.connect("0x5ef30b9986345249bc32d8928B7ee64DE9435E39", signer)

        const initialBalance = await signer.getBalance()

        //Deploy proxy
        const factory = DSProxyFactory__factory.connect('0xA26e15C895EFc0616177B7c1e7270A4C7D51C997', signer)
        const tx = await factory.build(signer.address);
        const events = await factory.queryFilter(factory.filters.Created(), tx.blockNumber)
        expect(events[0].args.proxy).to.properAddress
        proxy = DSProxy__factory.connect(events[0].args.proxy, signer)

        //Open vault
        actions = DssProxyActions__factory.connect("0x82ecD135Dce65Fbc6DbdD0e4237E0AF93FFD5038", signer)
        const callData = actions.interface.encodeFunctionData(
            "openLockETHAndDraw",
            [
                manager.address,
                "0x19c0976f590D67707E62397C87829d896Dc0f1F1",
                ethJoin,
                daiJoin,
                utils.formatBytes32String("ETH-A"),
                utils.parseUnits("50000")
            ]
        )

        await proxy.execute(actions.address, callData, {value: utils.parseEther("100")})

        dai = IERC20__factory.connect(daiAddress, signer);
        weth = IERC20__factory.connect(wethAddress, signer);
        expect(await dai.balanceOf(signer.address)).to.eq(utils.parseUnits("50000"))
        //gas consumption means we can't perform strict equality
        expect(await signer.getBalance()).to.be.bignumber.that.is.lessThan(initialBalance.sub(utils.parseEther("100")))

        cdpId = await manager.last(proxy.address)
        urn = await manager.urns(cdpId);
        const _vat = await manager.vat();
        vat = VatLike__factory.connect(_vat, signer);

        const [collateral, debt] = await currentDebtAndCollateral()

        expect(collateral).to.be.bignumber.that.is.eq(utils.parseEther("100"))
        expect(debt).to.be.bignumber.that.is.eq(utils.parseUnits("50000"))

        const migratorFactory = (await ethers.getContractFactory("MakerETHMigrator", signer)) as MakerETHMigrator__factory;
        testObj = await migratorFactory.deploy(uniswapFactory, wethAddress, daiAddress);
        await testObj.deployed();

        expect(testObj.address).to.properAddress;

        console.log("testObj", testObj.address)
        console.log("proxy", proxy.address)
    });

    async function currentDebtAndCollateral() {
        const ilks = await manager.ilks(cdpId)
        const [, rate, , ,] = await vat.ilks(ilks);
        const [collateral, debt] = await vat.urns(ilks, urn);
        const vatDai = await vat.dai(urn)
        return [collateral, debt.mul(rate).sub(vatDai).div(BigNumber.from(10).pow(27))]
    }

    // 4
    describe("migrate", async () => {
        // xit("can pay part of the debt", async () => {
        //     const initialBalance = await signer.getBalance();
        //     const [initialCollateral, initialDebt] = await currentDebtAndCollateral();
        //
        //     const daiWad = utils.parseUnits("10000");
        //     const etherWad = utils.parseEther("20");
        //     await dai.approve(proxy.address, daiWad)
        //
        //     const callData = testObj.interface.encodeFunctionData(
        //         "payDebt",
        //         [
        //             manager.address,
        //             ethJoin,
        //             daiJoin,
        //             cdpId,
        //             etherWad,
        //             daiWad
        //         ]
        //     )
        //     await proxy.execute(testObj.address, callData)
        //     expect(await dai.balanceOf(signer.address)).to.eq(utils.parseUnits("40000"))
        //     expect(await signer.getBalance()).to.be.bignumber.that.is.gt(initialBalance.add(utils.parseEther("19")))
        //     const [collateral, debt] = await currentDebtAndCollateral();
        //     expect(collateral).to.be.bignumber.that.is.eq(initialCollateral.sub(etherWad))
        //     expect(debt).to.be.bignumber.that.is.eq(initialDebt.sub(daiWad))
        // });
        //
        // xit("can pay all debt", async () => {
        //     const initialBalance = await signer.getBalance();
        //     const [initialCollateral, initialDebt] = await currentDebtAndCollateral();
        //
        //     await dai.approve(proxy.address, initialDebt)
        //
        //     const callData = testObj.interface.encodeFunctionData(
        //         "payAllDebt",
        //         [
        //             manager.address,
        //             ethJoin,
        //             daiJoin,
        //             cdpId,
        //             initialCollateral
        //         ]
        //     )
        //     await proxy.execute(testObj.address, callData)
        //     expect(await dai.balanceOf(signer.address)).to.be.eq(0)
        //     expect(await signer.getBalance()).to.be.bignumber.that.is.gt(initialBalance.add(utils.parseEther("79")))
        //     const [collateral, debt] = await currentDebtAndCollateral();
        //     expect(collateral).to.be.eq(0)
        //     expect(debt).to.be.eq(0)
        // });

        it("can pay all debt with a DAI flash swap and repay ETH", async () => {
            await dai.transfer("0x0000000000000000000000000000000000000000", utils.parseUnits("50000"));
            expect(await dai.balanceOf(signer.address)).to.be.eq(0)
            const initialBalance = await signer.getBalance();
            const [initialCollateral,] = await currentDebtAndCollateral();
            const callData = testObj.interface.encodeFunctionData(
                "payAllDebt",
                [
                    manager.address,
                    ethJoin,
                    daiJoin,
                    cdpId,
                    initialCollateral,
                    testObj.address
                ]
            )

            console.log("initialBalance=" + utils.formatEther(initialBalance));

            await proxy.execute(testObj.address, callData)

            const balanceAfterExecuting = await signer.getBalance();
            console.log("balanceAfterExecuting=" + utils.formatEther(balanceAfterExecuting));


            expect(await dai.balanceOf(signer.address)).to.be.eq(0)
            expect(await dai.balanceOf(proxy.address)).to.be.eq(0)
            expect(await weth.balanceOf(proxy.address)).to.be.eq(0)
            const proxyOwner = await proxy.owner();
            expect(proxyOwner).to.properAddress
            expect(proxyOwner).to.be.eq(signer.address)
            expect(await signer.getBalance()).to.be.bignumber.that.is.gt(initialBalance.add(utils.parseEther("81")))
            const [collateral, debt] = await currentDebtAndCollateral();
            expect(collateral).to.be.eq(0)
            expect(debt).to.be.eq(0)
        });
    });

});