//! Worldgen golden-hash regression test.
//!
//! Regenerates a fixed corpus of 100 worlds through the `worldgen` module and
//! compares the sha256 of each block array against golden hashes captured
//! from the Classic-Worldgen-RE black-box oracle (the original Minecraft
//! Classic server driven through its Python/Docker harness). A mismatch means
//! world generation no longer produces byte-identical worlds.
//!
//! Usage: zig build worldgen-test -Doptimize=ReleaseSafe
//!
//! Corpus provenance: the first 15 cases are hand-picked edges (seed
//! extremes, dimension extremes, the Classic default 256x64x256); the
//! remaining 85 come from the SplitMix64 stream seeded with
//! 0x636C2D776C67656E ("cl-wlgen"), consuming two draws per case -- the
//! first wrapped to a signed i64 seed, the second split into three 3-bit
//! fields with `4 + (field % 6)` as the log2 of each axis (16..512). All
//! dimensions are powers of two >= 16 with volume <= 2^31 - 1. Hashes were
//! captured once through the oracle's persistent worker protocol
//! (Classic-Worldgen-RE fuzzer_v2/ORACLE.md); the recipe above plus the RE
//! harness is enough to regenerate them. Note that the 48-bit Java Random
//! seed scramble legitimately makes seed 0 and i64 min (and -1 and i64 max)
//! produce identical worlds.

const std = @import("std");
const worldgen = @import("worldgen");

const Case = struct {
    seed: i64,
    width: u32,
    height: u32,
    depth: u32,
    sha256: *const [64]u8,
};

const golden = [_]Case{
    // Hand-picked edges: seed extremes and dimension extremes.
    .{ .seed = 0, .width = 256, .height = 64, .depth = 256, .sha256 = "efc04daa0fae040b36ad2ad336a2b18faa5eecaa2fdf476edfae0133ad0c5b08" },
    .{ .seed = 1, .width = 256, .height = 64, .depth = 256, .sha256 = "46075549dbb070c4fa42e56484e76ea83cadc72f7317f10b64076376124fefe8" },
    .{ .seed = -1, .width = 256, .height = 64, .depth = 256, .sha256 = "9fac24f641617677080c03f22c65540f89e620bd9745439b878c0846ced61936" },
    .{ .seed = 12345, .width = 256, .height = 64, .depth = 256, .sha256 = "823a2139e9a41e0b00c617eb5050ae73d4899f2275a3ec29a99a67eccb1a7f0a" },
    .{ .seed = -12345, .width = 256, .height = 64, .depth = 256, .sha256 = "2a008de3f7300d984ab9ec028088951e1181e8d82d82cc84eaabf603b5020894" },
    .{ .seed = -9223372036854775808, .width = 256, .height = 64, .depth = 256, .sha256 = "efc04daa0fae040b36ad2ad336a2b18faa5eecaa2fdf476edfae0133ad0c5b08" },
    .{ .seed = 9223372036854775807, .width = 256, .height = 64, .depth = 256, .sha256 = "9fac24f641617677080c03f22c65540f89e620bd9745439b878c0846ced61936" },
    .{ .seed = 0, .width = 16, .height = 16, .depth = 16, .sha256 = "bfebed11d3769b3bd214441d6d12a4941a90b70e7859a7eda87e00c564bf25b7" },
    .{ .seed = -9223372036854775808, .width = 16, .height = 16, .depth = 16, .sha256 = "bfebed11d3769b3bd214441d6d12a4941a90b70e7859a7eda87e00c564bf25b7" },
    .{ .seed = 9223372036854775807, .width = 16, .height = 16, .depth = 16, .sha256 = "ab0c29d0c459519283cc86a0eb1c96ec3efd1220e67b7992c98bb3055f587588" },
    .{ .seed = 0, .width = 512, .height = 128, .depth = 512, .sha256 = "9b1c81a2ccf72c3dd1104304e5fd0133a63bace4a9a21b0bfc42e42840932bc9" },
    .{ .seed = 0, .width = 1024, .height = 16, .depth = 16, .sha256 = "4ddec9dfedd8d3c5fd1dcbde515001ce6eaa2ed7a1bf44667537ced7e2480efa" },
    .{ .seed = 0, .width = 16, .height = 16, .depth = 1024, .sha256 = "190e0698032d1f05125a04df7b7934845ec2a7750934b68884246e37674375ab" },
    .{ .seed = 0, .width = 64, .height = 32, .depth = 256, .sha256 = "f685879755844dbe518fe648af310571ccc512d067af5e0ec611aa537751e864" },
    .{ .seed = 424242, .width = 128, .height = 64, .depth = 128, .sha256 = "3be94799751842dd49cd98c40d4045ed2275e9c7867794b04517f33a8de0a141" },
    // SplitMix64-derived cases (stream seed 0x636C2D776C67656E, see above).
    .{ .seed = -5779115992067710610, .width = 128, .height = 64, .depth = 128, .sha256 = "1067c9004331512f84c7dff9c8c1587697ab0d8af24718d426a7509e77436bba" },
    .{ .seed = 3067673659247815628, .width = 64, .height = 64, .depth = 64, .sha256 = "d3e698a06619c0d23385b2139be93ac9734f60833cba60e649c1dfdc982dae67" },
    .{ .seed = 165414938082953365, .width = 64, .height = 16, .depth = 32, .sha256 = "478e7a3659f472d24aaa37fa2fe33c6378795e6f4770f8df5cc63d30336fe143" },
    .{ .seed = 1708020596889526119, .width = 512, .height = 256, .depth = 64, .sha256 = "d13b34063dd2dbdbf26596303fa93bc477c20748c45819c8a62dcf5b0ad81cf9" },
    .{ .seed = 3220098103439132498, .width = 64, .height = 512, .depth = 512, .sha256 = "b84b5335c5c48a83983a1ebb86471269e292a2c8ece9a75ef2c812aa168fe0e6" },
    .{ .seed = 6756188221188177745, .width = 512, .height = 128, .depth = 256, .sha256 = "d4a7e953fa0e911b58d12a37ebe1a50120dccb365ff91c96cecdad8efc16e28c" },
    .{ .seed = -608479080652426302, .width = 256, .height = 64, .depth = 128, .sha256 = "eb7fac80d816221a18c1de5e1a8041889fc43eaec7cf7edb30eb9be2238cfff6" },
    .{ .seed = 2660261468396457871, .width = 64, .height = 512, .depth = 512, .sha256 = "e7a6a68831fa2bf039f0b4a8667d0d2cc50d4fd5eb3e84ad8681374b0365bb57" },
    .{ .seed = 2966870262471294086, .width = 512, .height = 256, .depth = 512, .sha256 = "0c8b27ec3092787177f2b9fbb644d5c3e8aef5981c46017b6aa9d9b149617684" },
    .{ .seed = 2245228512823966887, .width = 128, .height = 128, .depth = 32, .sha256 = "687e33df136f0e1df07ac6646bb73b06aecab3c3ab406c696a9f80bd3c658e83" },
    .{ .seed = -2429358958614236524, .width = 128, .height = 16, .depth = 256, .sha256 = "75f80e2803fb531c56be39c8f5c100c4fc0faa9bd3fa46075134961bef66c88d" },
    .{ .seed = 7193299059781639049, .width = 512, .height = 64, .depth = 32, .sha256 = "e8a5f8cb0a8c48c8a747fc142aab9db34b3bb7055bf507342a60c130173c7856" },
    .{ .seed = 6753006661145874992, .width = 128, .height = 64, .depth = 16, .sha256 = "f72f7fafbf0dcc55f6c161fa03345edff4190272a513b21763fc5411e5bdf9eb" },
    .{ .seed = -6393019180427966310, .width = 128, .height = 512, .depth = 256, .sha256 = "82f0664d4539a012ca0ff9a3025523124a6356ec54ecd1146062789a21014164" },
    .{ .seed = 1956454830287949607, .width = 16, .height = 128, .depth = 256, .sha256 = "ef8c23c5b3e7c57605d4685570c3f3f39b00e62349a2f6a280bda97589e5f017" },
    .{ .seed = 5814348819488896451, .width = 256, .height = 256, .depth = 32, .sha256 = "5b1c9955fb901ba8180027cfe1c40e576c9d140e6b72311ddf586e9a06835408" },
    .{ .seed = 2819431745395682604, .width = 32, .height = 32, .depth = 128, .sha256 = "1e2ed2ffb59d61b64eb8c16510c31a3e06260d1fb29f3469784859439fdf2d8c" },
    .{ .seed = 5580563911201401526, .width = 128, .height = 512, .depth = 256, .sha256 = "fb438061ef5fef0ca80c87940d7e7cf724d266957f468f49691c6318d62636f6" },
    .{ .seed = -2760835073062364033, .width = 256, .height = 512, .depth = 512, .sha256 = "ae7cd290d6f0e4b2f8f398d42d18e9064a17d079d887fef923aebc78101818ba" },
    .{ .seed = 4379546510345323168, .width = 32, .height = 16, .depth = 512, .sha256 = "aeeb7bda2697071eee8487b2d75fecefada7b582dc5f3972a7fc37e52d924139" },
    .{ .seed = -7554961507287088336, .width = 16, .height = 16, .depth = 128, .sha256 = "e806b1b6d2be788c3d6b7ba971d747d19720b62839501ef54be91b1e597216c3" },
    .{ .seed = 5518588828427627048, .width = 16, .height = 128, .depth = 128, .sha256 = "fad6bf45f8a9b8895c1bea25fcdb93f5a988e97064257bd86b38f1ddb01c85d8" },
    .{ .seed = 4090625666086713341, .width = 16, .height = 256, .depth = 16, .sha256 = "e442966354bd5437c3d48a3d18ec625ee61d854b700f1eed3c7eb80c9fa3cb84" },
    .{ .seed = -6360734826033159746, .width = 512, .height = 16, .depth = 128, .sha256 = "ebf421f58b788602f3eb1a40a803427602aca2a034e7e69ebba6e383a17af252" },
    .{ .seed = 2664784111459616351, .width = 256, .height = 64, .depth = 16, .sha256 = "8f8d1ff1f420af6f0ef54b534a833e7b2a7df4d95279a30ba66dd79ab0d4c7e4" },
    .{ .seed = -8748481232587491781, .width = 128, .height = 32, .depth = 128, .sha256 = "405979d13b8373feb3e45deaad28c626a9052a1d0a74039d89f98896875e4a13" },
    .{ .seed = -6743755318746232704, .width = 64, .height = 32, .depth = 32, .sha256 = "c8cca29e99c7d0a4cb7ebb4263c164e51ecf9abbe9cd225ee0ada130fa180b50" },
    .{ .seed = -4196888503469606836, .width = 128, .height = 128, .depth = 64, .sha256 = "f844d949e0017ea7a29ae2e357abda313a2e536412d56619d541d809c855ecac" },
    .{ .seed = -2465237045985964853, .width = 256, .height = 256, .depth = 32, .sha256 = "f80b675dffcaa7d02a5c0575edf1efcd848325ffb6cd957876ebf2536526f430" },
    .{ .seed = 6829312034911460439, .width = 512, .height = 32, .depth = 128, .sha256 = "3121d28060466208cf24ea25f634fcf3fcca6f2b7a543c9903cdef5f139f92b6" },
    .{ .seed = 3806245139053160299, .width = 512, .height = 32, .depth = 16, .sha256 = "fda6ae23312520d6f221f905d8d7355d27c7486e2504825dad3a11d73bfd1184" },
    .{ .seed = -6401362466489113251, .width = 512, .height = 512, .depth = 32, .sha256 = "e5d9ec912ad8e2c03d243214734a8ee3e49f362801e8f24a8d24625cdd7c9304" },
    .{ .seed = -2242264763941142589, .width = 256, .height = 64, .depth = 128, .sha256 = "db729183a8310dce1e77f14e2dcdd49797189108e5dd9a149cd6206284942cff" },
    .{ .seed = -8772246059606569663, .width = 32, .height = 64, .depth = 16, .sha256 = "03fa2998ca30621d97cb43847831a742b1df9d77a7a03c35e4dd0b47d05da17a" },
    .{ .seed = -1742609256321932342, .width = 512, .height = 512, .depth = 512, .sha256 = "8d14a5f611365e8efc6db81280828749444d027aea258d6dac8ee376b3648186" },
    .{ .seed = -1688823923247076117, .width = 512, .height = 512, .depth = 128, .sha256 = "79de674cf99b5a7cbe880c7ad2d78f32c6446989fd249595fbc2d6cecd3a239b" },
    .{ .seed = -442823408638138269, .width = 512, .height = 512, .depth = 32, .sha256 = "a91dac7a40d0501d5b2b04c40c8c3a96fffc060dff7132f7295b5a89086540f6" },
    .{ .seed = -260411239452888848, .width = 32, .height = 512, .depth = 256, .sha256 = "d9a60e14f21cbde63077e1913eafaaa98bf68a5ed7c633ea7067055e7fac053e" },
    .{ .seed = -1363552155304881220, .width = 128, .height = 64, .depth = 256, .sha256 = "af06012ee63192e19ebbd31676a8d40f438eb4ad7dadee8b484edfd6bbce9b4d" },
    .{ .seed = -4198753271350004817, .width = 256, .height = 16, .depth = 256, .sha256 = "ee77f287807bec6c394e51a05ded7185b440881dd3840e69efb8a97ce1388788" },
    .{ .seed = -5922109422280077773, .width = 256, .height = 32, .depth = 64, .sha256 = "c2e38c7f3665d81d6b53e5e51cb6c4b8ea9de8c4de338275a5b4b0d0a3fb5a7f" },
    .{ .seed = -3679665120517349118, .width = 32, .height = 256, .depth = 512, .sha256 = "b725df123da2a2b189721d1aae3e93c0c8f029f0cd614b37de049b327074f63c" },
    .{ .seed = 8448362559980364544, .width = 64, .height = 16, .depth = 512, .sha256 = "1e8c5929331504f3fc704e00066ff30745945c7325069b987fd4a6b43d7c807f" },
    .{ .seed = 2779105544761967228, .width = 64, .height = 16, .depth = 128, .sha256 = "b246269843c45d8dd3d39e259a74deb31a8ae24211d221613442eafe8f1e42d3" },
    .{ .seed = 967126329227661489, .width = 128, .height = 128, .depth = 16, .sha256 = "8071e78ac6656b8534668885f28ea57bc17d941601f58d43ef642c6e29599c65" },
    .{ .seed = -3726561917950161393, .width = 16, .height = 64, .depth = 32, .sha256 = "ffd3abbe9edeaf7ce3bb13c54d1270b7b17e2ee62c59730130b0cab1e56a2101" },
    .{ .seed = -8619556741036309554, .width = 512, .height = 512, .depth = 512, .sha256 = "6fe544677ccfb187fe3a5cdba09a79e103b2a8a0a37eb7af58d2ce203c0dc100" },
    .{ .seed = 815668840646754549, .width = 512, .height = 16, .depth = 64, .sha256 = "f910ed98c039a31fc5e8755c3de73cd95a61a6fd6c4a521fb0910c67985f9550" },
    .{ .seed = 6744009988312622523, .width = 16, .height = 256, .depth = 64, .sha256 = "07c505a2f06b35e56c5dad067d914f897fabee675d59f6624cce07ad9c7c317d" },
    .{ .seed = -2178118665092737702, .width = 256, .height = 512, .depth = 64, .sha256 = "80d079c22dbae9330d99ef6a5541993541d7bdf85fca4f65028552bfba67bcae" },
    .{ .seed = -4223195976799379617, .width = 64, .height = 256, .depth = 16, .sha256 = "e24d02226cf1608e6bcbd25418953bfb5da7b69bce860d43e6559ebd65c3c54d" },
    .{ .seed = -6216668207279126841, .width = 256, .height = 128, .depth = 256, .sha256 = "8c205f9dd0c1a0069e2ead2743a85c495e5de4c0b9f94e00a4682c1c7ec3fb57" },
    .{ .seed = -7019645084578872266, .width = 512, .height = 128, .depth = 16, .sha256 = "0703e44fe801f799656e41617a6aa72b166435946a8646b9af5501274c6b27b6" },
    .{ .seed = -170997226910710568, .width = 32, .height = 32, .depth = 512, .sha256 = "bd8737f542b5a1ddf53dad372cc2d73cd499dc5a088b1dd3101669cb5536252e" },
    .{ .seed = -1841137621644721664, .width = 32, .height = 512, .depth = 64, .sha256 = "298bd2e9389e002eb21f2001b55647f24cf69269892aef29d14500d54fae7e34" },
    .{ .seed = -2569175419688908502, .width = 128, .height = 512, .depth = 32, .sha256 = "ed25a91fd692f5b03062259d86bc0133e0038b0c0f99b1f276354ed4e54984e2" },
    .{ .seed = 2320772921045868262, .width = 16, .height = 32, .depth = 64, .sha256 = "56029041f077d68a6328c68a3a49cb8812c2eb6b9c3ac598ac931b28a734e59b" },
    .{ .seed = 6131692969403522328, .width = 512, .height = 128, .depth = 64, .sha256 = "183bd443e28c833713dbb29678240c4adc9f0611b2d701689df7e80aa9916889" },
    .{ .seed = 3348571880738144636, .width = 512, .height = 64, .depth = 512, .sha256 = "6241056c99b67cfca4de036104940a96149f41433e644a2c91b62d29c023b95e" },
    .{ .seed = 5296100775300098288, .width = 256, .height = 16, .depth = 16, .sha256 = "02bf681861aa7da12bd9297ce04ed42b9baa966b4fdcfa87c067f6e7a9f2adae" },
    .{ .seed = -3455927313420510886, .width = 32, .height = 32, .depth = 256, .sha256 = "3d2f96ee3618a71f9efcac4d519f7c17a66979711039afc8c3f8436582a8f085" },
    .{ .seed = -8269941988003068844, .width = 32, .height = 512, .depth = 32, .sha256 = "df6a622cdb5d9793eeea8c71775d024c8de949550d593b48bd80b3a498fe4d9b" },
    .{ .seed = 650113618930702362, .width = 128, .height = 16, .depth = 16, .sha256 = "dfe094cd78b32590b291a7dde184784691fb257bea79ddfef6291fa4bb55c289" },
    .{ .seed = 4331488370016989330, .width = 256, .height = 128, .depth = 16, .sha256 = "a3bc1d8cd263bea8b72d50bad887d75bbfad41333e5768c22711bb24a5b4ad14" },
    .{ .seed = 7583413686190290122, .width = 32, .height = 16, .depth = 32, .sha256 = "49799c5b0c6c49fefecb8f8cbdb437bc77ff89f7a3c6a1cfd5ca0a854dd7625c" },
    .{ .seed = -4643607208270685334, .width = 512, .height = 128, .depth = 16, .sha256 = "e5f57f883efad3b285a4ed82c74aa9347d03201fbc2e6b163d8441951d8a15d3" },
    .{ .seed = -6893321990758068878, .width = 32, .height = 128, .depth = 128, .sha256 = "fd0b645bcb937d74ba742207e134cb7b26a4f1c62b09ed828171a82a27b9881d" },
    .{ .seed = 5415351869313791415, .width = 64, .height = 64, .depth = 512, .sha256 = "bc906e3d45bb14d440d56cd172681a0817fd12b612f885ec3424728946580f63" },
    .{ .seed = -367060770396640678, .width = 512, .height = 256, .depth = 256, .sha256 = "aa5ff8fabf790da745c6c6f85d432683eb154a5c0dcce4c2240c7d32163c28bb" },
    .{ .seed = 6993832387855217514, .width = 128, .height = 512, .depth = 64, .sha256 = "b921247de9dea678da9ed32ed5250e6fdb538dbc0a9b322521a707334046c0c8" },
    .{ .seed = 7111482033592387145, .width = 128, .height = 128, .depth = 64, .sha256 = "c506887cee856454836943d805f0f30dc15d83656a638f9f9c7d9616696573e8" },
    .{ .seed = 862085136379198092, .width = 128, .height = 128, .depth = 64, .sha256 = "43d5186d4929906754636eb0c48073ed17fa880e5f18ddcfa86392aa5cedf6c1" },
    .{ .seed = 1995035789205268242, .width = 256, .height = 16, .depth = 64, .sha256 = "f572227a8af2b140afaf81786d7d04e21deebf27cad36b70c2fd2e2de03fc79d" },
    .{ .seed = -5868865959933831051, .width = 128, .height = 64, .depth = 64, .sha256 = "3b82aa6ebcf5618ac03fdc15187845e8e92073acfc0ddc6b9fd7d03805d85783" },
    .{ .seed = -147031215465071381, .width = 32, .height = 64, .depth = 64, .sha256 = "32b84f5d41473086c3b9d805e9b7e835e3898ff7542589e157bfe73d21cace76" },
    .{ .seed = -2062266946723111095, .width = 32, .height = 256, .depth = 256, .sha256 = "672807be8c6d8412b9350e62b60fb9521eedadc02538e8868e0136bb4f83758d" },
    .{ .seed = 8749255562838734486, .width = 256, .height = 16, .depth = 32, .sha256 = "c1687a91bf9f25f1f25434bf304ce5c3771197a0f3464c845057d4799aec4538" },
    .{ .seed = 1932713774384076165, .width = 64, .height = 512, .depth = 32, .sha256 = "6068081cd7420cb0160cd77cb9a408e2a40b72246eff9a866194067b69c0e242" },
    .{ .seed = -5830280813607206545, .width = 512, .height = 512, .depth = 64, .sha256 = "5b5d22ef498bdc5a9a888dc7e118580548683187cc3d75343a1c4f2d46a6dffd" },
    .{ .seed = 3212443685375919791, .width = 256, .height = 128, .depth = 512, .sha256 = "0ba472b2e1c0432891b1ae32db17aabdc095f95b0e4cc15d3cda2862c682fc28" },
    .{ .seed = -5305110349627676122, .width = 32, .height = 16, .depth = 128, .sha256 = "2597f67bb4405f9a09a5c7950ca6fdb0bfc382195ed4eaa07ba88c35e568ff52" },
    .{ .seed = 8357340453039912761, .width = 64, .height = 512, .depth = 32, .sha256 = "c4e8bfc07ce35bf17748b10cc92cb85d19ca80af379e442c46f2da20f81b285e" },
    .{ .seed = -5057645728966726470, .width = 16, .height = 512, .depth = 256, .sha256 = "bfc72c7b8dc6941b6789e10ec5801531202ed9353f6b98c84c8c39ffdb1b7747" },
    .{ .seed = -1732570213468141405, .width = 32, .height = 128, .depth = 256, .sha256 = "0f47cbf8446f86a714514772ec7eee004c05a1f652443361c06f9c11f1e29cf8" },
    .{ .seed = -930797275953572584, .width = 64, .height = 256, .depth = 64, .sha256 = "0cb079815a489f013bc4082cddc6b3202b164ae9a939ebe96a5368db316bfe0e" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    const started = std.Io.Timestamp.now(init.io, .awake);
    var failures: usize = 0;
    var total_blocks: u64 = 0;

    for (golden, 0..) |case, index| {
        const dimensions: worldgen.level.world_dimensions = .{
            .width = case.width,
            .height = case.height,
            .depth = case.depth,
        };
        if (!dimensions.validate()) {
            std.debug.print("worldgen golden hash: corpus case {d} has invalid dimensions {d}x{d}x{d}\n", .{
                index, case.width, case.height, case.depth,
            });
            std.process.exit(1);
        }

        const generated = try worldgen.generate(gpa, scratch.allocator(), case.seed, dimensions);
        defer gpa.free(generated.blocks);
        total_blocks += generated.blocks.len;

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(generated.blocks, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, &actual, case.sha256)) {
            failures += 1;
            std.debug.print(
                "FAIL {d}: seed={d} {d}x{d}x{d}\n  expected {s}\n  actual   {s}\n",
                .{ index, case.seed, case.width, case.height, case.depth, case.sha256, &actual },
            );
        }
        _ = scratch.reset(.retain_capacity);
    }

    const elapsed_ns = std.Io.Timestamp.durationTo(started, std.Io.Timestamp.now(init.io, .awake)).nanoseconds;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

    if (failures == 0) {
        std.debug.print("worldgen golden hash: {d}/{d} worlds byte-identical to the oracle ({d} blocks, {d:.2}s)\n", .{
            golden.len, golden.len, total_blocks, elapsed_s,
        });
        return;
    }
    std.debug.print("worldgen golden hash: {d} of {d} worlds FAILED\n", .{ failures, golden.len });
    std.process.exit(1);
}
