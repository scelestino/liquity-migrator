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
    ManagerLike__factory
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
    let signer: SignerWithAddress
    let testObj: MakerETHMigrator;
    let proxy: DSProxy
    let manager: ManagerLike
    let cdpId: BigNumber
    let dai: IERC20
    let actions: DssProxyActions

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

        dai = IERC20__factory.connect("0x6b175474e89094c44da98b954eedeac495271d0f", signer);
        expect(await dai.balanceOf(signer.address)).to.eq(utils.parseUnits("50000"))
        //gas consumption means we can't perform strict equality
        expect(await signer.getBalance()).to.be.bignumber.that.is.lessThan(initialBalance.sub(utils.parseEther("100")))

        cdpId = await manager.last(proxy.address)


        const migratorFactory = (await ethers.getContractFactory("MakerETHMigrator", signer)) as MakerETHMigrator__factory;
        testObj = await migratorFactory.deploy();
        await testObj.deployed();

        expect(testObj.address).to.properAddress;
    });

    // 4
    describe("migrate", async () => {
        it("can pay debt 2", async () => {
            const initialBalance = await signer.getBalance();

            const daiWad = utils.parseUnits("10000");
            await dai.approve(proxy.address, daiWad)

            const callData = testObj.interface.encodeFunctionData(
                "payDebt",
                [
                    manager.address,
                    ethJoin,
                    daiJoin,
                    cdpId,
                    utils.parseEther("20"),
                    daiWad
                ]
            )
            await proxy.execute(testObj.address, callData)
            expect(await dai.balanceOf(signer.address)).to.eq(utils.parseUnits("40000"))
            expect(await signer.getBalance()).to.be.bignumber.that.is.gt(initialBalance.add(utils.parseEther("19")))
        });
    });

});