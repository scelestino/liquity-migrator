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
    ITroveManager,
    ITroveManager__factory,
    MakerETHMigrator,
    MakerETHMigrator__factory,
    ManagerLike,
    ManagerLike__factory,
    FlashSwapManager,
    FlashSwapManager__factory,
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
    const uniswapFactory = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
    const daiAddress = "0x6b175474e89094c44da98b954eedeac495271d0f";
    const wethAddress = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
    const lusdAddress = "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0";
    const borrowerOperations = "0x24179CD81c9e782A4096035f7eC97fB8B783e007";
    let signer: SignerWithAddress
    let migrator: MakerETHMigrator;
    let proxy: DSProxy
    let vaultManager: ManagerLike
    let troveManager: ITroveManager
    let cdpId: BigNumber
    let dai: IERC20
    let weth: IERC20
    let actions: DssProxyActions
    let urn: string;
    let vat: VatLike;
    let flashManager: FlashSwapManager;

    before(async () => {
        const signers = await ethers.getSigners()
        signer = signers[0]
        vaultManager = ManagerLike__factory.connect("0x5ef30b9986345249bc32d8928B7ee64DE9435E39", signer)
        troveManager = ITroveManager__factory.connect("0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2", signer)

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
                vaultManager.address,
                "0x19c0976f590D67707E62397C87829d896Dc0f1F1",
                ethJoin,
                daiJoin,
                utils.formatBytes32String("ETH-A"),
                utils.parseUnits("5000")
            ]
        )

        await proxy.execute(actions.address, callData, {value: utils.parseEther("100")})

        dai = IERC20__factory.connect(daiAddress, signer);
        weth = IERC20__factory.connect(wethAddress, signer);
        expect(await dai.balanceOf(signer.address)).to.eq(utils.parseUnits("5000"))
        //gas consumption means we can't perform strict equality
        expect(await signer.getBalance()).to.be.bignumber.that.is.lessThan(initialBalance.sub(utils.parseEther("100")))

        cdpId = await vaultManager.last(proxy.address)
        urn = await vaultManager.urns(cdpId);
        const _vat = await vaultManager.vat();
        vat = VatLike__factory.connect(_vat, signer);

        const [collateral, debt] = await currentDebtAndCollateral()

        expect(collateral).to.be.bignumber.that.is.eq(utils.parseEther("100"))
        expect(debt).to.be.bignumber.that.is.eq(utils.parseUnits("5000"))

        const FlashSwapManagerFactory = (await ethers.getContractFactory("FlashSwapManager", signer)) as FlashSwapManager__factory;
        flashManager = await FlashSwapManagerFactory.deploy(uniswapFactory, wethAddress, daiAddress, lusdAddress);
        await flashManager.deployed();
        expect(flashManager.address).to.properAddress;

        const migratorFactory = (await ethers.getContractFactory("MakerETHMigrator", signer)) as MakerETHMigrator__factory;
        migrator = await migratorFactory.deploy(flashManager.address, lusdAddress, borrowerOperations);
        await migrator.deployed();
        expect(migrator.address).to.properAddress;
    });

    async function currentDebtAndCollateral() {
        const ilks = await vaultManager.ilks(cdpId)
        const [, rate, , ,] = await vat.ilks(ilks);
        const [collateral, debt] = await vat.urns(ilks, urn);
        const vatDai = await vat.dai(urn)
        return [collateral, debt.mul(rate).sub(vatDai).div(BigNumber.from(10).pow(27))]
    }

    describe("migrate", async () => {
        it("can pay all debt with a DAI flash swap and repay ETH", async () => {
            await dai.transfer("0x0000000000000000000000000000000000000000", utils.parseUnits("5000"));
            expect(await dai.balanceOf(signer.address)).to.be.eq(0)
            const initialBalance = await signer.getBalance();
            const [initialMakerCollateral,] = await currentDebtAndCollateral();
            const callData = migrator.interface.encodeFunctionData(
                "migrateVaultToTrove",
                [vaultManager.address, ethJoin, daiJoin, cdpId, migrator.address, BigNumber.from(500)]
            )

            await proxy.execute(migrator.address, callData)

            expect(await dai.balanceOf(signer.address)).to.be.eq(0)
            expect(await dai.balanceOf(proxy.address)).to.be.eq(0)
            expect(await weth.balanceOf(proxy.address)).to.be.eq(0)
            const proxyOwner = await proxy.owner();
            expect(proxyOwner).to.properAddress
            expect(proxyOwner).to.be.eq(signer.address)
            expect(await signer.getBalance()).to.be.bignumber.that.is.lt(initialBalance)
            const [makerCollateral, makerDebt] = await currentDebtAndCollateral();
            expect(makerCollateral).to.be.eq(0)
            expect(makerDebt).to.be.eq(0)
            const [liquityDebt, liquityCollateral, ,] = await troveManager.getEntireDebtAndColl(proxy.address)
            expect(liquityCollateral).to.be.bignumber.eq(initialMakerCollateral)
            expect(liquityDebt).to.be.bignumber.gt(utils.parseUnits("5000"))
        });
    });
});